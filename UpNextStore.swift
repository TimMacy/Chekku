import Foundation
import Combine

enum SyncPhase: Equatable {
    case idle, checking, loading, saving, scrobbling, current(Date), failed
    var isBusy: Bool {
        switch self {
        case .checking, .loading, .saving, .scrobbling: return true
        default: return false
        }
    }
}

@MainActor
final class UpNextStore: ObservableObject {
    private static let imageModePreferenceKey = "confirmedEpisodeImageMode"
    @Published private(set) var shows: [TrackedShow] = []
    @Published private(set) var episodeImageMode: EpisodeImageMode = .backdrop
    @Published private(set) var phase: SyncPhase = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeEpisodeID: Int?
    @Published private(set) var requiresRefresh = false
    @Published private(set) var isConnected: Bool
    @Published private(set) var needsConnection = false
    @Published private(set) var isConnecting = false
    @Published private(set) var deviceCode: DeviceCode?
    @Published private(set) var connectionError: String?
    @Published var clientID: String

    let isPreview: Bool
    private let api: any WeTrakrServing
    private let cache: any QueueStorage
    private let defaults: UserDefaults
    private var snapshot: QueueSnapshot?
    private(set) var operation: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private(set) lazy var infuse = InfuseMonitor { [weak self] item in
        guard let self else { throw CancellationError() }
        try await self.scrobbleWatched(item)
    }

    init(api: any WeTrakrServing = APIClient(), cache: any QueueStorage = FileQueueStorage(),
         isPreview: Bool = false, defaults: UserDefaults = .standard) {
        self.api = api
        self.cache = cache
        self.defaults = defaults
        self.isPreview = isPreview
        isConnected = api.isConnected
        clientID = api.isConnected ? api.clientID : ""
        if !api.isConnected {
            defaults.removeObject(forKey: "clientID")
            defaults.removeObject(forKey: Self.imageModePreferenceKey)
        }
        if let sessionID = api.sessionID?.uuidString,
           let saved = defaults.dictionary(forKey: Self.imageModePreferenceKey),
           saved["sessionID"] as? String == sessionID,
           let rawMode = saved["mode"] as? String,
           let mode = EpisodeImageMode(rawValue: rawMode) {
            episodeImageMode = mode
        }
        if let error = (api as? APIClient)?.restorationError { connectionError = error }
        do {
            if let saved = try cache.load(), saved.sessionID == api.sessionID {
                snapshot = saved
                shows = saved.shows
            }
        } catch {
            snapshot = nil
        }
    }

    var visibleShows: [TrackedShow] {
        shows.filter { $0.nextWatchingEpisode?.hasAired() == true }
    }

    var canMarkWatched: Bool {
        isConnected && !needsConnection && !phase.isBusy && !isConnecting && !requiresRefresh && !isPreview
    }

    func open() {
        guard isConnected else { return }
        refresh()
        if !isPreview { infuse.start() }
    }

    func refresh(force: Bool = false) {
        guard operation == nil, phase != .scrobbling, !isConnecting, isConnected else { return }
        errorMessage = nil
        phase = .checking
        operation = Task {
            defer { operation = nil }
            do {
                let updated = try await fetchQueue(force: force)
                try publish(updated)
                requiresRefresh = false
                needsConnection = false
                phase = .current(Date())
            } catch is CancellationError {
                phase = .idle
            } catch {
                fail(error)
            }
        }
    }

    func markWatched(_ show: TrackedShow) {
        guard canMarkWatched, operation == nil, let episode = show.nextWatchingEpisode,
              visibleShows.contains(where: { $0.id == show.id && $0.nextWatchingEpisode?.id == episode.id }) else { return }
        errorMessage = nil
        activeEpisodeID = episode.id
        phase = .saving
        operation = Task {
            defer {
                activeEpisodeID = nil
                operation = nil
            }
            var saved = false
            do {
                try await api.markWatched(episodeID: episode.id)
                saved = true
                let updated = try await fetchQueue(force: true)
                guard !updated.shows.contains(where: { $0.nextWatchingEpisode?.id == episode.id }) else {
                    throw WeTrakrError.message("Up Next hasn't advanced to the next episode yet.")
                }
                try publish(updated)
                phase = .current(Date())
            } catch is CancellationError {
                phase = .idle
            } catch {
                requiresRefresh = true
                let prefix = saved ? "Episode saved. " : ""
                fail(error, prefix: prefix, suffix: " Refresh before marking another episode.")
            }
        }
    }

    func connect() {
        let key = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isConnecting, operation == nil, phase != .scrobbling else { return }
        clientID = key
        defaults.set(key, forKey: "clientID")
        connectionError = nil
        deviceCode = nil
        isConnecting = true
        connectionTask = Task {
            defer {
                isConnecting = false
                deviceCode = nil
                connectionTask = nil
            }
            do {
                let code = try await api.deviceCode(clientID: key)
                guard code.approvalURL != nil else {
                    throw WeTrakrError.message("WeTrakr returned an invalid sign-in page.")
                }
                deviceCode = code
                let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                var interval = max(1, code.interval)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    try Task.checkCancellation()
                    if Date() >= deadline { break }
                    do {
                        if try await api.pollToken(code: code, clientID: key) {
                            try? cache.remove()
                            shows = []
                            snapshot = nil
                            episodeImageMode = .backdrop
                            defaults.removeObject(forKey: Self.imageModePreferenceKey)
                            isConnected = true
                            needsConnection = false
                            requiresRefresh = false
                            errorMessage = nil
                            isConnecting = false
                            refresh(force: true)
                            if !isPreview {
                                infuse.stop()
                                infuse.start()
                            }
                            return
                        }
                    } catch WeTrakrError.http(429, _, _) {
                        interval += 5
                    }
                }
                throw WeTrakrError.message("The sign-in code expired. Connect again to get a new one.")
            } catch is CancellationError {
                connectionError = nil
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    func cancelConnection() {
        connectionTask?.cancel()
    }

    func disconnect() {
        guard operation == nil, phase != .scrobbling, !isConnecting else { return }
        do {
            try api.disconnect()
            infuse.stop()
            clientID = ""
            defaults.removeObject(forKey: "clientID")
            defaults.removeObject(forKey: Self.imageModePreferenceKey)
            deviceCode = nil
            connectionError = nil
            isConnected = false
            needsConnection = false
            shows = []
            snapshot = nil
            episodeImageMode = .backdrop
            phase = .idle
            errorMessage = nil
            requiresRefresh = false
            try cache.remove()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func close() {
        operation?.cancel()
        connectionTask?.cancel()
        infuse.stop()
    }

    private func scrobbleWatched(_ item: ScrobbleItem) async throws {
        while let operation {
            await operation.value
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        guard isConnected, !needsConnection, !isConnecting else { throw WeTrakrError.signInRequired }
        let previousPhase = phase
        phase = .scrobbling
        do {
            try await api.scrobbleWatched(item)
            try Task.checkCancellation()
        } catch {
            phase = previousPhase
            if !Task.isCancelled {
                if case WeTrakrError.http(401, _, _) = error { fail(error) }
                if case WeTrakrError.signInRequired = error { fail(error) }
            }
            throw error
        }
        phase = previousPhase
        refresh(force: true)
    }

    private func fetchQueue(force: Bool) async throws -> QueueSnapshot {
        let mode = try await api.episodeImageMode()
        try Task.checkCancellation()
        guard let sessionID = api.sessionID else { throw WeTrakrError.signInRequired }
        if episodeImageMode != mode { episodeImageMode = mode }
        let savedMode = defaults.dictionary(forKey: Self.imageModePreferenceKey)
        if savedMode?["sessionID"] as? String != sessionID.uuidString ||
           savedMode?["mode"] as? String != mode.rawValue {
            defaults.set(["sessionID": sessionID.uuidString, "mode": mode.rawValue],
                         forKey: Self.imageModePreferenceKey)
        }
        let activity = try await api.lastActivity()
        try Task.checkCancellation()
        let now = Date()
        if !force, var snapshot, !snapshot.needsReload(activity: activity, now: now) {
            snapshot.checkedAt = now
            return snapshot
        }
        phase = .loading
        let updatedShows = try await api.nextShows()
        try Task.checkCancellation()
        return QueueSnapshot(sessionID: sessionID, shows: updatedShows, activity: activity,
                             fetchedAt: now, checkedAt: Date(),
                             schemaVersion: QueueSnapshot.currentSchemaVersion)
    }

    private func publish(_ snapshot: QueueSnapshot) throws {
        try cache.save(snapshot)
        self.snapshot = snapshot
        shows = snapshot.shows
    }

    private func fail(_ error: Error, prefix: String = "", suffix: String = "") {
        if case WeTrakrError.http(401, _, _) = error { needsConnection = true }
        if case WeTrakrError.signInRequired = error { needsConnection = true }
        phase = .failed
        errorMessage = prefix + error.localizedDescription + suffix
    }
}
