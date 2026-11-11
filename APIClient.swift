import Foundation

@MainActor
protocol WeTrakrServing {
    var clientID: String { get }
    var sessionID: UUID? { get }
    var isConnected: Bool { get }
    func lastActivity() async throws -> String?
    func episodeImageMode() async throws -> EpisodeImageMode
    func nextShows() async throws -> [TrackedShow]
    func markWatched(episodeID: Int) async throws
    func scrobbleWatched(_ item: ScrobbleItem) async throws
    func deviceCode(clientID: String) async throws -> DeviceCode
    func pollToken(code: DeviceCode, clientID: String) async throws -> Bool
    func disconnect() throws
}

@MainActor
final class APIClient: WeTrakrServing {
    private static let appVersion: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "Chekku/\(version)"
    }()

    private let session: URLSession
    private let storage: any CredentialStorage
    private var credentials: Credentials?
    private var episodeMetadata: [Int: (milestone: String?, fetchedAt: Date)] = [:]
    private var refreshTask: Task<Void, Error>?
    let restorationError: String?

    var clientID: String { credentials?.clientID ?? "" }
    var sessionID: UUID? { credentials?.sessionID }
    var isConnected: Bool { credentials != nil }

    init(session: URLSession = .shared, storage: any CredentialStorage = KeychainStorage()) {
        self.session = session
        self.storage = storage
        do {
            credentials = try storage.load()
            restorationError = nil
        } catch {
            restorationError = error.localizedDescription
        }
    }

    func deviceCode(clientID: String) async throws -> DeviceCode {
        let body = try JSONSerialization.data(withJSONObject: ["client_id": clientID])
        let response = try await send(path: "/oauth/device/code", method: "POST",
                                      clientID: clientID, body: body)
        return try APIJSON.decoder().decode(DeviceCode.self, from: response.data)
    }

    func pollToken(code: DeviceCode, clientID: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["client_id": clientID, "code": code.deviceCode])
        do {
            let response = try await send(path: "/oauth/device/token", method: "POST",
                                          clientID: clientID, body: body)
            let token = try APIJSON.decoder().decode(TokenResponse.self, from: response.data)
            try accept(token, clientID: clientID, sessionID: UUID())
            return true
        } catch WeTrakrError.http(400, _, let code) where code == "authorization_pending" {
            return false
        }
    }

    func disconnect() throws {
        try storage.remove()
        refreshTask?.cancel()
        refreshTask = nil
        credentials = nil
        episodeMetadata.removeAll()
    }

    func lastActivity() async throws -> String? {
        let response = try await authorized(path: "/sync/last_activities")
        return try APIJSON.decoder().decode(LastActivities.self, from: response.data).all
    }

    func episodeImageMode() async throws -> EpisodeImageMode {
        let response = try await authorized(path: "/account/settings")
        return try APIJSON.decoder().decode(AccountSettings.self, from: response.data).episodeImageMode
    }

    func nextShows() async throws -> [TrackedShow] {
        var shows: [TrackedShow] = []
        var seen: Set<Int> = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let response = try await authorized(path: "/sync/tracking/watching/shows", query: [
                URLQueryItem(name: "extended", value: "show_level_1,episode_level_1,interactions"),
                URLQueryItem(name: "sort_by", value: "my_last_watched"),
                URLQueryItem(name: "sort_dir", value: "desc"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "page", value: String(page))
            ])
            let items = try APIJSON.decoder().decode([TrackedShow].self, from: response.data)
            for show in items where seen.insert(show.id).inserted { shows.append(show) }
            guard let pageCountText = response.http.value(forHTTPHeaderField: "X-Pagination-Page-Count"),
                  let pageCount = Int(pageCountText), pageCount >= 0 else {
                throw WeTrakrError.message("WeTrakr didn't return valid paging information. The list wasn't updated.")
            }
            if pageCount == 0 && !items.isEmpty {
                throw WeTrakrError.message("WeTrakr returned inconsistent paging information.")
            }
            if page >= pageCount { break }
            page += 1
        }
        let queue = shows
        return try await withThrowingTaskGroup(of: (Int, TrackedShow).self) { group in
            for (index, show) in queue.prefix(4).enumerated() {
                group.addTask { (index, try await self.showDetails(show)) }
            }
            var updated = queue
            var nextIndex = min(4, queue.count)
            while let (index, show) = try await group.next() {
                updated[index] = show
                if nextIndex < queue.count {
                    let index = nextIndex
                    let show = queue[index]
                    group.addTask { (index, try await self.showDetails(show)) }
                    nextIndex += 1
                }
            }
            return updated
        }
    }

    private func showDetails(_ source: TrackedShow) async throws -> TrackedShow {
        try Task.checkCancellation()
        var show = source
        if let episode = show.nextWatchingEpisode,
           episode.milestone == nil, episode.hasAired() {
            if let saved = episodeMetadata[episode.id],
               Date().timeIntervalSince(saved.fetchedAt) < 900 {
                show.nextWatchingEpisode?.milestone = saved.milestone
            } else {
                do {
                    let response = try await authorized(path: "/episodes/\(episode.id)")
                    let details = try APIJSON.decoder().decode(Episode.self, from: response.data)
                    guard details.id == episode.id else {
                        throw WeTrakrError.message("WeTrakr returned details for a different episode.")
                    }
                    try Task.checkCancellation()
                    episodeMetadata[episode.id] = (details.milestone, Date())
                    show.nextWatchingEpisode?.milestone = details.milestone
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                }
            }
        }
        if (show.episodesLeft ?? 0) > 0 {
            do {
                let response = try await authorized(path: "/shows/\(show.id)/seasons", query: [
                    URLQueryItem(name: "extended", value: "interactions")
                ])
                let seasons = try APIJSON.decoder().decode([SeasonTracking].self, from: response.data)
                show.updateRemainingTime(from: seasons)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return show
    }

    func markWatched(episodeID: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "episodes": [["id": episodeID, "status": "watched"]],
            "allow_rewatch": false
        ])
        let response = try await authorized(path: "/sync/tracking", method: "POST", body: body)
        let update = try APIJSON.decoder().decode(TrackingUpdate.self, from: response.data)
        try update.confirmEpisodeWasWatched()
    }

    func scrobbleWatched(_ item: ScrobbleItem) async throws {
        var payload: [String: Any] = ["progress": 100, "app_version": Self.appVersion]
        switch item.kind {
        case .movie:
            payload["movie"] = ["ids": item.ids]
        case .episode(let season, let number):
            payload["show"] = ["ids": item.ids]
            payload["episode"] = ["season": season, "number": number]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let threshold = String(Int(InfuseMonitor.watchedThreshold))
        let response = try await authorized(path: "/scrobble/stop", method: "POST",
                                            query: [URLQueryItem(name: "min_progress", value: threshold)],
                                            body: body)
        guard response.http.statusCode == 201 else {
            throw WeTrakrError.message("WeTrakr didn't confirm that \(item.title) was marked watched.")
        }
    }

    private func authorized(path: String, method: String = "GET", query: [URLQueryItem] = [],
                            body: Data? = nil) async throws -> Response {
        guard let credentials else { throw WeTrakrError.signInRequired }
        if credentials.expiresAt.timeIntervalSinceNow < 60 {
            try await refreshToken(replacing: credentials.accessToken)
        }
        let accessToken = self.credentials?.accessToken
        do {
            return try await send(path: path, method: method, clientID: credentials.clientID,
                                  accessToken: accessToken, query: query, body: body)
        } catch WeTrakrError.http(401, _, _) {
            try await refreshToken(replacing: accessToken)
            return try await send(path: path, method: method, clientID: credentials.clientID,
                                  accessToken: self.credentials?.accessToken, query: query, body: body)
        }
    }

    private func refreshToken(replacing staleToken: String?) async throws {
        if let refreshTask { return try await refreshTask.value }
        guard let credentials else { throw WeTrakrError.signInRequired }
        guard credentials.accessToken == staleToken else { return }
        let task = Task {
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": credentials.refreshToken])
            let response = try await send(path: "/oauth/token/refresh", method: "POST",
                                          clientID: credentials.clientID, body: body)
            let token = try APIJSON.decoder().decode(TokenResponse.self, from: response.data)
            try accept(token, clientID: credentials.clientID, sessionID: credentials.sessionID)
        }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        try await task.value
    }

    private func accept(_ token: TokenResponse, clientID: String, sessionID: UUID) throws {
        guard !token.accessToken.isEmpty, !token.refreshToken.isEmpty, token.expiresIn > 0 else {
            throw WeTrakrError.message("WeTrakr returned an incomplete connection.")
        }
        let credentials = Credentials(clientID: clientID, sessionID: sessionID,
                                      accessToken: token.accessToken, refreshToken: token.refreshToken,
                                      expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn)))
        try storage.save(credentials)
        self.credentials = credentials
    }

    private struct Response {
        let data: Data
        let http: HTTPURLResponse
    }

    private struct ErrorResponse: Decodable {
        var error: String?
        var message: String?
    }

    private func send(path: String, method: String, clientID: String, accessToken: String? = nil,
                      query: [URLQueryItem] = [], body: Data? = nil) async throws -> Response {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.wetrakr.com"
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw WeTrakrError.message("Invalid WeTrakr request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(clientID, forHTTPHeaderField: "wetrakr-api-key")
        request.setValue("1", forHTTPHeaderField: "wetrakr-api-version")
        request.setValue("en-US", forHTTPHeaderField: "wetrakr-api-language")
        request.setValue(Self.appVersion, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        let (data, response) = result
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw WeTrakrError.message("WeTrakr returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw WeTrakrError.http(http.statusCode, error?.message ?? "WeTrakr returned error \(http.statusCode).",
                                   error?.error)
        }
        return Response(data: data, http: http)
    }
}