import Foundation
import Combine
import Network

struct InfuseNowPlaying: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var kind: String
        var tmdbID: String?
        var imdbID: String?
        var tvdbID: String?
        var season: Int?
        var episode: Int?
        var title: String?
        var seriesTitle: String?
    }
    var state: String
    var positionSeconds: Double?
    var durationSeconds: Double?
    var item: Item?

    var progress: Double? {
        guard let positionSeconds, let durationSeconds, durationSeconds > 0 else { return nil }
        return min(100, max(0, positionSeconds / durationSeconds * 100))
    }
}

struct ScrobbleItem: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case movie
        case episode(season: Int, number: Int)
    }
    var kind: Kind
    var tmdb: Int?
    var imdb: String?
    var tvdb: Int?
    var title: String

    init?(_ item: InfuseNowPlaying.Item) {
        tmdb = item.tmdbID.flatMap { Int($0) }
        imdb = item.imdbID.flatMap { $0.isEmpty ? nil : $0 }
        tvdb = item.tvdbID.flatMap { Int($0) }
        guard tmdb != nil || imdb != nil || tvdb != nil else { return nil }
        switch item.kind {
        case "movie":
            kind = .movie
            title = item.title ?? "Movie"
        case "episode":
            guard let season = item.season, let number = item.episode else { return nil }
            kind = .episode(season: season, number: number)
            title = String(format: "%@ S%02d | E%02d", item.seriesTitle ?? "Episode", season, number)
        default:
            return nil
        }
    }

    func isAnotherEpisode(of other: ScrobbleItem) -> Bool {
        guard case .episode = kind, case .episode = other.kind, self != other else { return false }
        if let tmdb, tmdb == other.tmdb { return true }
        if let tvdb, tvdb == other.tvdb { return true }
        return false
    }

    var ids: [String: Any] {
        var ids: [String: Any] = [:]
        if let tmdb { ids["tmdb"] = tmdb }
        if let imdb { ids["imdb"] = imdb }
        if let tvdb { ids["tvdb"] = tvdb }
        return ids
    }
}

@MainActor
final class InfuseMonitor: ObservableObject {
    static let watchedThreshold = 90.0
    private static let closeThreshold = 80.0
    private static let slowInterval: Duration = .seconds(60)
    private static let fastInterval: Duration = .seconds(10)

    enum Status: Equatable {
        case searching
        case idle
        case playing(title: String, progress: Int)
        case saving(title: String)
        case saved(title: String)
        case failed(title: String, message: String)
    }

    @Published private(set) var status: Status = .searching

    private let scrobble: (ScrobbleItem) async throws -> Void
    private var browser: NWBrowser?
    private var devices: [String: NWEndpoint] = [:]
    private var pollTask: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var lastPlayed: [String: (item: ScrobbleItem, progress: Double)] = [:]
    private var saved: Set<ScrobbleItem> = []
    private var saving: Set<ScrobbleItem> = []
    private var retryAfter: [ScrobbleItem: Date] = [:]
    private var rejected: Set<ScrobbleItem> = []
    private var hasFreshResult = false
    private var activity: (any NSObjectProtocol)?

    init(scrobble: @escaping (ScrobbleItem) async throws -> Void) {
        self.scrobble = scrobble
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_infuse-np._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.poll() else { return }
                await self?.sleep(for: interval)
            }
        }
    }

    private func sleep(for interval: Duration) async {
        guard !Task.isCancelled else { return }
        let wait = Task { _ = try? await Task.sleep(for: interval) }
        wake = wait
        await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
        if wake == wait { wake = nil }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        pollTask?.cancel()
        pollTask = nil
        wake = nil
        devices = [:]
        lastPlayed = [:]
        saved = []
        saving = []
        retryAfter = [:]
        rejected = []
        hasFreshResult = false
        status = .searching
        setFollowingPlayback(false)
    }

    private func setFollowingPlayback(_ isFollowing: Bool) {
        if isFollowing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "Following playback in Infuse")
        } else if !isFollowing, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [String: NWEndpoint] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            if found[name] == nil { found[name] = devices[name] ?? result.endpoint }
        }
        let isNew = found.keys.contains { devices[$0] == nil }
        devices = found
        if found.isEmpty { status = .searching }
        if isNew { wake?.cancel() }
    }

    private func poll() async -> Duration {
        let endpoints = devices
        var reports: [(device: String, report: InfuseNowPlaying)] = []
        await withTaskGroup(of: (String, InfuseNowPlaying)?.self) { group in
            for (name, endpoint) in endpoints {
                group.addTask { (try? await InfuseClient.nowPlaying(at: endpoint)).map { (name, $0) } }
            }
            for await report in group { if let report { reports.append(report) } }
        }
        guard !Task.isCancelled else { return Self.slowInterval }
        hasFreshResult = false
        var interval = Self.slowInterval
        let active = reports.filter { $0.report.state != "idle" && $0.report.item != nil }
        for (device, report) in active {
            guard !Task.isCancelled else { return Self.slowInterval }
            guard let item = report.item.flatMap(ScrobbleItem.init), let progress = report.progress else { continue }
            let previous = lastPlayed[device]
            lastPlayed[device] = (item, progress)
            if let previous, previous.progress >= Self.closeThreshold, item.isAnotherEpisode(of: previous.item) {
                await finish(previous.item)
            }
            if progress >= Self.watchedThreshold { await finish(item) }
            if progress >= Self.closeThreshold, !saved.contains(item) { interval = Self.fastInterval }
        }
        for item in Array(retryAfter.keys) { await finish(item) }
        guard !Task.isCancelled else { return Self.slowInterval }
        updateStatus(active.map(\.report))
        return interval
    }

    private func finish(_ item: ScrobbleItem) async {
        guard !Task.isCancelled, !saved.contains(item), !saving.contains(item),
              !rejected.contains(item) else { return }
        if let date = retryAfter[item], date > Date() { return }
        saving.insert(item)
        defer { saving.remove(item) }
        if retryAfter[item] == nil { status = .saving(title: item.title) }
        let failure: (any Error)?
        do {
            try await scrobble(item)
            failure = nil
        } catch {
            failure = error
        }
        guard !Task.isCancelled else { return }
        if let failure {
            if Self.isRejection(failure) {
                retryAfter[item] = nil
                rejected.insert(item)
            } else {
                retryAfter[item] = Date().addingTimeInterval(60)
            }
            status = .failed(title: item.title, message: failure.localizedDescription)
        } else {
            saved.insert(item)
            retryAfter[item] = nil
            status = .saved(title: item.title)
        }
        hasFreshResult = true
    }

    private static func isRejection(_ error: any Error) -> Bool {
        guard case WeTrakrError.http(let status, _, _) = error else { return false }
        return (400..<500).contains(status) && ![401, 408, 429].contains(status)
    }

    private func updateStatus(_ active: [InfuseNowPlaying]) {
        let playing = active.compactMap { report -> (ScrobbleItem, Double)? in
            guard let item = report.item.flatMap(ScrobbleItem.init), let progress = report.progress else { return nil }
            return (item, progress)
        }.first
        setFollowingPlayback(playing != nil)
        switch status {
        case .saved(let title), .failed(let title, _), .saving(let title):
            if hasFreshResult || playing == nil || playing?.0.title == title { return }
        default: break
        }
        if let (item, progress) = playing {
            status = .playing(title: item.title, progress: Int(progress))
        } else {
            status = devices.isEmpty ? .searching : .idle
        }
    }
}

enum InfuseClient {
    private final class Exchange: @unchecked Sendable {
        var data = Data()
        var continuation: CheckedContinuation<Data, Error>?
        let queue = DispatchQueue(label: "Chekku.Infuse")

        func finish(_ result: Result<Data, Error>, _ connection: NWConnection) {
            guard let continuation else { return }
            self.continuation = nil
            connection.cancel()
            continuation.resume(with: result)
        }
    }

    static func nowPlaying(at endpoint: NWEndpoint) async throws -> InfuseNowPlaying {
        let response = try await fetch(endpoint)
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response[..<separator.lowerBound], encoding: .utf8),
              head.hasPrefix("HTTP/1.1 200") || head.hasPrefix("HTTP/1.0 200") else {
            throw WeTrakrError.message("Infuse returned an invalid response.")
        }
        var body = Data(response[separator.upperBound...])
        if let length = head.split(separator: "\r\n").first(where: {
            $0.lowercased().hasPrefix("content-length:")
        }).flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }),
           length <= body.count {
            body = body.prefix(length)
        }
        return try JSONDecoder().decode(InfuseNowPlaying.self, from: body)
    }

    private static func fetch(_ endpoint: NWEndpoint) async throws -> Data {
        let exchange = Exchange()
        let connection = NWConnection(to: endpoint, using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            exchange.queue.async {
                exchange.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = "GET /nowplaying HTTP/1.1\r\nHost: infuse\r\nConnection: close\r\n\r\n"
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                            if let error { exchange.finish(.failure(error), connection) }
                        })
                        receive(connection, exchange)
                    case .failed(let error), .waiting(let error):
                        exchange.finish(.failure(error), connection)
                    default:
                        break
                    }
                }
                connection.start(queue: exchange.queue)
                exchange.queue.asyncAfter(deadline: .now() + 5) {
                    exchange.finish(.failure(WeTrakrError.message("Infuse didn't respond.")), connection)
                }
            }
        }
    }

    private static func receive(_ connection: NWConnection, _ exchange: Exchange) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
            if let content { exchange.data.append(content) }
            if let error {
                exchange.finish(.failure(error), connection)
            } else if isComplete {
                exchange.finish(.success(exchange.data), connection)
            } else if exchange.data.count > 1_000_000 {
                exchange.finish(.failure(WeTrakrError.message("Infuse's response was too large.")), connection)
            } else {
                receive(connection, exchange)
            }
        }
    }
}