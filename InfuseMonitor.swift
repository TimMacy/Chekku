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

struct ScrobbleItem: Sendable {
    enum Kind: Hashable, Sendable {
        case movie
        case episode(season: Int, number: Int)
    }
    struct Identity: Hashable, Sendable {
        let kind: Kind
        let tmdb: Int?
        let imdb: String?
        let tvdb: Int?
    }

    let identity: Identity
    var kind: Kind { identity.kind }
    let title: String

    init?(_ item: InfuseNowPlaying.Item) {
        let tmdb = item.tmdbID.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let imdb = item.imdbID.flatMap { $0.isEmpty ? nil : $0 }
        let tvdb = item.tvdbID.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        guard tmdb != nil || imdb != nil || tvdb != nil else { return nil }
        let kind: Kind
        switch item.kind {
        case "movie":
            kind = .movie
            title = item.title ?? "Movie"
        case "episode":
            guard let season = item.season, season >= 0,
                  let number = item.episode, number > 0 else { return nil }
            kind = .episode(season: season, number: number)
            title = String(format: "%@ S%02d | E%02d", item.seriesTitle ?? "Episode", season, number)
        default:
            return nil
        }
        identity = Identity(kind: kind, tmdb: tmdb, imdb: imdb, tvdb: tvdb)
    }

    var ids: [String: Any] {
        var ids: [String: Any] = [:]
        if let tmdb = identity.tmdb { ids["tmdb"] = tmdb }
        if let imdb = identity.imdb { ids["imdb"] = imdb }
        if let tvdb = identity.tvdb { ids["tvdb"] = tvdb }
        return ids
    }
}

@MainActor
final class InfuseMonitor: ObservableObject {
    static let watchedThreshold = 90.0
    private static let pollInterval: Duration = .seconds(10)

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
    private var discoveryID: UUID?
    private var devices: [String: NWEndpoint] = [:]
    private var pollTask: Task<Void, Never>?
    private var saved: Set<ScrobbleItem.Identity> = []
    private var pending: [ScrobbleItem.Identity: (item: ScrobbleItem, retryAt: Date)] = [:]
    private var rejected: Set<ScrobbleItem.Identity> = []
    private var hasFreshResult = false
    private var activity: (any NSObjectProtocol)?

    init(scrobble: @escaping (ScrobbleItem) async throws -> Void) {
        self.scrobble = scrobble
    }

    func start() {
        guard browser == nil else { return }
        let discoveryID = UUID()
        self.discoveryID = discoveryID
        let browser = NWBrowser(for: .bonjour(type: "_infuse-np._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.discoveryID == discoveryID else { return }
                self.update(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        discoveryID = nil
        browser?.cancel()
        browser = nil
        pollTask?.cancel()
        pollTask = nil
        devices = [:]
        saved.removeAll()
        pending.removeAll()
        rejected.removeAll()
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
            if found[name] == nil { found[name] = result.endpoint }
        }
        devices = found
        if found.isEmpty { status = .searching }
    }

    private func poll() async {
        let endpoints = Array(devices.values)
        var reports: [InfuseNowPlaying] = []
        await withTaskGroup(of: InfuseNowPlaying?.self) { group in
            for endpoint in endpoints {
                group.addTask { try? await InfuseClient.nowPlaying(at: endpoint) }
            }
            for await report in group { if let report { reports.append(report) } }
        }
        guard !Task.isCancelled else { return }
        hasFreshResult = false
        let active = reports.filter { $0.state == "playing" || $0.state == "paused" }
        for report in active {
            guard !Task.isCancelled else { return }
            guard let item = report.item.flatMap(ScrobbleItem.init), let progress = report.progress else { continue }
            if progress >= Self.watchedThreshold { await finish(item) }
        }
        for entry in Array(pending.values) {
            guard !Task.isCancelled else { return }
            await finish(entry.item)
        }
        if !Task.isCancelled { updateStatus(active) }
    }

    private func finish(_ item: ScrobbleItem) async {
        let key = item.identity
        guard !Task.isCancelled, !saved.contains(key), !rejected.contains(key) else { return }
        if let entry = pending[key], entry.retryAt > Date() { return }
        if pending[key] == nil { status = .saving(title: item.title) }
        do {
            try await scrobble(item)
            guard !Task.isCancelled else { return }
            saved.insert(key)
            pending[key] = nil
            status = .saved(title: item.title)
        } catch {
            guard !Task.isCancelled else { return }
            if Self.isRejection(error) {
                pending[key] = nil
                rejected.insert(key)
            } else {
                pending[key] = (item, Date().addingTimeInterval(60))
            }
            status = .failed(title: item.title, message: error.localizedDescription)
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
            } else if exchange.data.count > 1_000_000 {
                exchange.finish(.failure(WeTrakrError.message("Infuse's response was too large.")), connection)
            } else if isComplete {
                exchange.finish(.success(exchange.data), connection)
            } else {
                receive(connection, exchange)
            }
        }
    }
}