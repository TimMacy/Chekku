import Foundation

enum EpisodeImageMode: String, Equatable, Sendable {
    case visible, blur, backdrop

    init(apiValue: String?) {
        switch apiValue {
        case "visible", "still": self = .visible
        case "blur": self = .blur
        default: self = .backdrop
        }
    }
}

struct AccountSettings: Decodable, Sendable {
    struct Preferences: Decodable, Sendable {
        var episodeImageMode: String?
    }
    var preferences: Preferences?

    var episodeImageMode: EpisodeImageMode {
        EpisodeImageMode(apiValue: preferences?.episodeImageMode)
    }
}

struct TrackedShow: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    var posterPath: String?
    var backdropPath: String?
    var currentSeasonPosterPath: String?
    var nextWatchingEpisode: Episode?
    var interactions: Interactions?
    var seasonMinutesLeft: Int?

    var tracking: TrackingState? { interactions?.user?.tracking?.last }

    var episodesLeft: Int? {
        guard let total = tracking?.episodesTotal, let resolved = tracking?.episodesResolved else { return nil }
        return max(0, total - resolved)
    }

    var remainingText: String? {
        let episodes = episodesLeft.map { "\($0) \($0 == 1 ? "ep" : "eps") left" }
        let minutes = (seasonMinutesLeft ?? tracking?.minutesLeft).map(Self.duration)
        return [episodes, minutes].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    mutating func updateRemainingTime(from seasons: [SeasonTracking]) {
        seasonMinutesLeft = nil
        let regular = seasons.filter { $0.number > 0 }
        guard !regular.isEmpty,
              Set(regular.map(\.number)).count == regular.count,
              let total = tracking?.episodesTotal,
              let resolved = tracking?.episodesResolved else { return }
        var seasonTotal = 0
        var seasonResolved = 0
        var minutes = 0
        for season in regular {
            guard let state = season.interactions?.user?.tracking?.last,
                  let aired = state.episodesTotal, aired >= 0,
                  let resolved = state.episodesResolved, resolved >= 0,
                  let remaining = state.minutesLeft, remaining >= 0 else { return }
            seasonTotal += aired
            seasonResolved += resolved
            minutes += remaining
        }
        guard seasonTotal == total, seasonResolved == resolved else { return }
        seasonMinutesLeft = minutes
    }

    static func duration(_ minutes: Int) -> String {
        let minutes = max(0, minutes)
        if minutes < 60 { return "\(minutes)m" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    func artworkURL(for mode: EpisodeImageMode) -> URL? {
        if mode != .backdrop,
           let still = Artwork.url(nextWatchingEpisode?.stillPath, size: "w780") {
            return still
        }
        return artworkURL
    }

    var artworkURL: URL? {
        Artwork.url(backdropPath, size: "w780")
            ?? Artwork.url(currentSeasonPosterPath ?? posterPath, size: "w500")
    }
}

struct SeasonTracking: Decodable, Sendable {
    let number: Int
    var interactions: Interactions?
}

struct Episode: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    var title: String?
    var seasonNumber: Int?
    var number: Int?
    var airDate: String?
    var airDatetime: String?
    var runtime: Int?
    var stillPath: String?
    var milestone: String?
    var isUpcoming: Bool?

    var label: String {
        guard let seasonNumber, let number else { return "Next episode" }
        return String(format: "S%02d | E%02d", seasonNumber, number)
    }

    var milestoneLabel: String? {
        switch milestone {
        case "new_series": return "NEW SERIES"
        case "new_season": return "NEW SEASON"
        case "new_episode": return "NEW EPISODE"
        case "series_premiere": return "SERIES PREMIERE"
        case "season_premiere": return "SEASON PREMIERE"
        case "mid_season_premiere": return "MID-SEASON PREMIERE"
        case "mid_season_finale": return "MID-SEASON FINALE"
        case "season_finale": return "SEASON FINALE"
        case "series_finale": return "SERIES FINALE"
        default: return nil
        }
    }

    var airDateLabel: String? {
        guard let airDate else { return nil }
        let day = String(airDate.prefix(10))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        guard let date = parser.date(from: day) else { return nil }
        parser.dateFormat = "MM/dd/yyyy"
        return parser.string(from: date)
    }

    func hasAired(at date: Date = Date()) -> Bool {
        if let airDatetime, let instant = APIJSON.date(airDatetime) { return instant <= date }
        return isUpcoming != true
    }
}

struct Interactions: Codable, Equatable, Sendable {
    var user: UserInteraction?
}

struct UserInteraction: Codable, Equatable, Sendable {
    var tracking: Tracking?
}

struct Tracking: Codable, Equatable, Sendable {
    var last: TrackingState?
}

struct TrackingState: Codable, Equatable, Sendable {
    var progress: Double?
    var episodesTotal: Int?
    var episodesResolved: Int?
    var episodesWatched: Int?
    var minutesLeft: Int?
}

struct LastActivities: Decodable, Sendable {
    var all: String?
}

struct TrackingUpdate: Decodable, Sendable {
    struct Added: Decodable, Sendable {
        struct Watched: Decodable, Sendable { var episodes: Int? }
        var watched: Watched?
    }
    struct RejectedItem: Decodable, Sendable {
        var id: Int?
        var error: String?
    }
    var added: Added?
    var notFound: [String: [RejectedItem]]?
    var errored: [String: [RejectedItem]]?

    func confirmEpisodeWasWatched() throws {
        if let error = errored?.values.flatMap({ $0 }).first {
            throw WeTrakrError.message(error.error ?? "WeTrakr didn't save the episode.")
        }
        if notFound?.values.contains(where: { !$0.isEmpty }) == true {
            throw WeTrakrError.message("WeTrakr couldn't find that episode.")
        }
        guard added?.watched?.episodes == 1 else {
            throw WeTrakrError.message("WeTrakr didn't confirm that the episode was marked watched.")
        }
    }
}

struct DeviceCode: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int

    var approvalURL: URL? {
        guard var url = URLComponents(string: verificationUrl),
              url.scheme == "https", url.host == "wetrakr.com" else { return nil }
        url.queryItems = (url.queryItems ?? []) + [URLQueryItem(name: "code", value: userCode)]
        return url.url
    }
}

struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

struct Credentials: Codable, Sendable {
    let clientID: String
    let sessionID: UUID
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

struct QueueSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2
    let sessionID: UUID
    var shows: [TrackedShow]
    var activity: String?
    var fetchedAt: Date
    var checkedAt: Date
    var schemaVersion: Int?

    func needsReload(activity: String?, now: Date) -> Bool {
        if schemaVersion != Self.currentSchemaVersion { return true }
        if self.activity != activity || now.timeIntervalSince(fetchedAt) >= 900 { return true }
        return shows.contains {
            guard let date = $0.nextWatchingEpisode?.airDatetime.flatMap(APIJSON.date) else { return false }
            return date > fetchedAt && date <= now
        }
    }
}

enum Artwork {
    static func url(_ path: String?, size: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.scheme == "https", url.host != nil { return url }
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
    }
}

enum APIJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum WeTrakrError: LocalizedError {
    case message(String)
    case http(Int, String, String?)
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .signInRequired: return "Connect your WeTrakr account to update your episodes."
        case .http(let status, let message, _):
            if status == 401 { return "Your connection expired. Connect to WeTrakr again." }
            if status == 429 { return "WeTrakr's request limit was reached. Wait a little, then refresh." }
            return message
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
