import AppKit
import SwiftUI

struct EpisodeCard: View {
    let show: TrackedShow
    let isSaving: Bool
    let isEnabled: Bool
    var imageMode: EpisodeImageMode = .backdrop
    let markWatched: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    private let width: CGFloat = 252

    var body: some View {
        VStack(spacing: 0) {
            Button(action: markWatched) {
                ZStack(alignment: .top) {
                    ArtworkView(url: show.artworkURL(for: imageMode))
                        .id(show.artworkURL(for: imageMode))
                        .frame(width: width, height: width * 9 / 16)
                        .compositingGroup()
                        .blur(radius: imageMode == .blur ? 12 : 0)
                        .clipped()
                    HStack(alignment: .top, spacing: 4) {
                        episodeNumber
                            .font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color(red: 0.12, green: 0.41, blue: 0.72), in: RoundedRectangle(cornerRadius: 3))
                        Spacer(minLength: 0)
                        if let milestone = show.nextWatchingEpisode?.milestoneLabel {
                            Text(milestone)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 7).padding(.vertical, 6)
                                .background(milestoneColor, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    .padding(5)
                    if isSaving || ((isHovering || isFocused) && isEnabled) {
                        Color.black.opacity(0.50)
                        VStack(spacing: 7) {
                            if isSaving {
                                ProgressView().controlSize(.large)
                                Text("Saving…").font(.system(size: 13, weight: .medium))
                            } else {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 40, weight: .light))
                                Text("Mark watched").font(.system(size: 13, weight: .medium))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: width, height: width * 9 / 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($isFocused)
            .modifier(PointingHandCursor())
            .disabled(!isEnabled)
            .onHover { isHovering = $0 && isEnabled }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovering = false }
            }
            .help("Mark \(show.title), \(show.nextWatchingEpisode?.label ?? "next episode") watched")
            .accessibilityLabel("Mark \(show.title), \(show.nextWatchingEpisode?.label ?? "next episode") watched")
            .accessibilityHint("Saves this episode to your WeTrakr watch history.")
            remainingBar
            Link(show.title, destination: showURL)
                .buttonStyle(TitleLinkStyle(normalColor: .primary))
                .modifier(PointingHandCursor())
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)
                .padding(.top, 14)
                .help(show.title)
            episodeTitle
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .help(show.nextWatchingEpisode?.title ?? "")
            if let date = show.nextWatchingEpisode?.airDateLabel {
                Label(date, systemImage: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 8)
                    .accessibilityLabel("Air date \(date)")
            }
        }
        .frame(width: width)
    }

    private var milestoneColor: Color {
        switch show.nextWatchingEpisode?.milestone {
        case "new_series", "new_season":
            return Color(.sRGB, red: 8 / 255, green: 165 / 255, blue: 8 / 255)
        case "series_premiere", "season_premiere":
            return Color(.sRGB, red: 8 / 255, green: 166 / 255, blue: 166 / 255)
        case "mid_season_premiere":
            return Color(.sRGB, red: 70 / 255, green: 158 / 255, blue: 208 / 255)
        case "mid_season_finale":
            return Color(.sRGB, red: 36 / 255, green: 68 / 255, blue: 191 / 255)
        case "season_finale":
            return Color(.sRGB, red: 195 / 255, green: 11 / 255, blue: 80 / 255)
        case "series_finale":
            return Color(.sRGB, red: 166 / 255, green: 8 / 255, blue: 166 / 255)
        case "new_episode":
            return Color(.displayP3, red: 74 / 255, green: 162 / 255, blue: 48 / 255)
        default:
            return Color(.sRGB, red: 127 / 255, green: 67 / 255, blue: 179 / 255)
        }
    }

    private var episodeNumber: Text {
        guard let season = show.nextWatchingEpisode?.seasonNumber,
              let number = show.nextWatchingEpisode?.number else {
            return Text("Next episode")
        }
        return Text(String(format: "S%02d", season)).bold()
            + Text(String(format: " | E%02d", number))
    }

    private var showURL: URL {
        URL(string: "https://wetrakr.com/shows/\(show.id)")!
    }

    @ViewBuilder
    private var episodeTitle: some View {
        let title = show.nextWatchingEpisode?.title ?? ""
        if let season = show.nextWatchingEpisode?.seasonNumber,
           let number = show.nextWatchingEpisode?.number {
            Link(title, destination: showURL.appendingPathComponent("seasons/\(season)/episodes/\(number)"))
                .buttonStyle(TitleLinkStyle(normalColor: .secondary))
                .modifier(PointingHandCursor())
        } else {
            Text(title)
        }
    }

    private var remainingBar: some View {
        ZStack(alignment: .leading) {
            AppStyle.surface
            if let progress = show.tracking?.progress {
                AppStyle.accent.frame(width: width * max(0, min(100, progress)) / 100)
            }
            Text(show.remainingText ?? show.nextWatchingEpisode?.runtime.map { TrackedShow.duration($0) } ?? "")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(.white)
        }
        .frame(height: 27)
    }

}

private struct TitleLinkStyle: ButtonStyle {
    let normalColor: Color

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, normalColor: normalColor)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let normalColor: Color
        @State private var isHovering = false
        private let hoverColor = Color(.sRGB, red: 130 / 255, green: 131 / 255, blue: 1, opacity: 1)

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering || configuration.isPressed ? hoverColor : normalColor)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .onHover { isHovering = $0 }
        }
    }
}
