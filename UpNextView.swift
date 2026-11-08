import AppKit
import SwiftUI

enum AppStyle {
    static let background = Color(red: 0.105, green: 0.105, blue: 0.115)
    static let surface = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let accent = Color(red: 0.40, green: 0.32, blue: 1)
    static let success = Color(red: 0.37, green: 0.78, blue: 0.49)
}

struct UpNextView: View {
    @ObservedObject var store: UpNextStore
    @State private var showingConnection = false
    @State private var isConnectionHovered = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if store.needsConnection {
                        Button("Connect") { showingConnection = true }
                    }
                }
                .padding(14)
                .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            if !store.isConnected {
                ConnectionView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleShows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(store.visibleShows) { show in
                            EpisodeCard(show: show,
                                        isSaving: store.activeEpisodeID == show.nextWatchingEpisode?.id,
                                        isEnabled: (store.canMarkWatched || store.isPreview) && !showingConnection,
                                        imageMode: store.episodeImageMode) {
                                store.markWatched(show)
                            }
                            .allowsHitTesting(!showingConnection)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .background(AppStyle.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 660, minHeight: 430)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingConnection) {
            ConnectionView(store: store, isSheet: true) { showingConnection = false }
                .padding(24)
                .background(AppStyle.background)
                .preferredColorScheme(.dark)
        }
        .onAppear { store.open() }
        .onDisappear { store.close() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Image(systemName: "forward").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary)
                    Text("Up Next").font(.system(size: 29, weight: .semibold))
                }
                if store.isConnected {
                    Text(store.isPreview ? "Preview · sample data" :
                            "\(store.visibleShows.count) \(store.visibleShows.count == 1 ? "show" : "shows")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            syncStatus
            Button {
                store.refresh(force: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(RefreshButtonStyle())
            .disabled(!store.isConnected || store.phase.isBusy || store.isConnecting)
            .controlSize(.large)
            .help("Check WeTrakr for updated episodes")
            Button {
                showingConnection = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 17)).padding(8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isConnectionHovered && isConnectionEnabled ? Color.white : Color.secondary)
            .onHover { isConnectionHovered = $0 }
            .disabled(!isConnectionEnabled)
            .help("WeTrakr connection")
            .accessibilityLabel("WeTrakr connection")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    private var isConnectionEnabled: Bool {
        !store.phase.isBusy && !store.isConnecting && !store.isPreview
    }

    @ViewBuilder
    private var syncStatus: some View {
        HStack(spacing: 7) {
            if store.phase.isBusy {
                ProgressView().controlSize(.small)
                Text(store.phase == .saving ? "Saving episode…" :
                        store.phase == .scrobbling ? "Saving playback…" :
                        store.phase == .loading ? "Loading episodes…" : "Checking for updates…")
            } else if store.isPreview {
                Text("Sample data").foregroundStyle(.secondary)
            } else if case .current(let date) = store.phase {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppStyle.success)
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .help(date.formatted(date: .complete, time: .standard))
            } else if store.phase == .failed {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Update failed")
            } else {
                Text(store.isConnected ? "Ready to update" : "Not connected").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: store.phase.isBusy ? "arrow.clockwise" :
                    store.phase == .failed ? "wifi.exclamationmark" : "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(store.phase.isBusy ? "Checking your episodes" :
                    store.phase == .failed ? "Couldn't update your episodes" : "You're caught up")
                .font(.title3.weight(.medium))
            Text(store.phase.isBusy ? "Your Up Next list will appear here." :
                    store.phase == .failed ? "Click Refresh to try again." : "No aired episodes are waiting in your Watching list.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isConnected && !store.isPreview {
                InfuseStatusView(monitor: store.infuse)
            }
            Spacer()
            if !store.visibleShows.isEmpty {
                Text(store.isPreview ? "Connect an account to mark episodes as watched." : "Click a poster to mark its episode as watched.").foregroundStyle(.secondary)
                Text("|").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Link("Powered by WeTrakr", destination: URL(string: "https://wetrakr.com/")!)
                .modifier(PointingHandCursor())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct InfuseStatusView: View {
    @ObservedObject var monitor: InfuseMonitor

    var body: some View {
        HStack(spacing: 5) {
            switch monitor.status {
            case .searching:
                Text("Infuse not found").foregroundStyle(.secondary)
                    .help("Turn on Infuse › Settings › Playback › Now Playing API.")
            case .idle:
                Text("Infuse connected").foregroundStyle(.secondary)
            case .playing(let title, let progress):
                Image(systemName: "play.fill").foregroundStyle(.secondary)
                Text("\(title) · \(progress)%").foregroundStyle(.secondary)
                    .help("Marked watched at \(Int(InfuseMonitor.watchedThreshold))%.")
            case .saving(let title):
                ProgressView().controlSize(.mini)
                Text("Marking \(title) watched…")
            case .saved(let title):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppStyle.success)
                Text("\(title) marked watched")
            case .failed(let title, let message):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Couldn't mark \(title) watched").help(message)
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

private struct RefreshButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : isHovering ? 1 : 0.6) : 0.3)
                .onHover { isHovering = $0 }
        }
    }
}

struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isEnabled ? .link : nil)
        } else {
            content.background(CursorRegion(isEnabled: isEnabled))
        }
    }
}

private struct CursorRegion: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        view.isEnabled = isEnabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var isEnabled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
        }
    }
}
