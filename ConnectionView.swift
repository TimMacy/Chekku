import SwiftUI

struct ConnectionView: View {
    @ObservedObject var store: UpNextStore
    @Environment(\.openURL) private var openURL
    var isSheet = false
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: store.isConnected && !store.needsConnection ? "link.circle.fill" : "link.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(store.isConnected && !store.needsConnection ? AppStyle.success : AppStyle.accent)
                Spacer()
                if isSheet {
                    Button("Done", action: dismiss)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(ConnectionActionStyle())
                }
            }
            Text(store.isConnected && !store.needsConnection ? "Connected to WeTrakr" : "Connect to WeTrakr")
                .font(.system(size: 23, weight: .semibold))
            if store.isConnected && !store.needsConnection {
                Text("Account connected. The episode list refreshes when the app opens, an episode is marked watched, or Refresh is clicked.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Manage connected apps on WeTrakr") {
                        openURL(URL(string: "https://wetrakr.com/profile/settings/api")!)
                    }
                    Spacer(minLength: 0)
                    Button("Forget connection") { store.disconnect() }
                        .disabled(store.phase == .scrobbling)
                        .help("Remove the saved login, app key, and episode list from this Mac.")
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(ConnectionActionStyle())
            } else {
                Text("Connect once to see your next episodes and mark them watched.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("WeTrakr app key").font(.callout.weight(.medium))
                    TextField("client_id", text: $store.clientID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .controlSize(.large)
                        .disabled(store.isConnecting)
                        .onSubmit { store.connect() }
                        .accessibilityLabel("WeTrakr app key")
                    Text("Use the client_id from Settings → API on WeTrakr.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let code = store.deviceCode, let url = code.approvalURL {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(code.userCode)
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Link("Approve on WeTrakr", destination: url)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for your approval…").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { store.cancelConnection() }
                        }
                    }
                    .padding(16)
                    .background(AppStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button {
                        store.connect()
                    } label: {
                        HStack {
                            if store.isConnecting { ProgressView().controlSize(.small) }
                            Text(store.isConnecting ? "Connecting…" : "Connect")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isConnecting)
                }
                Link("API app registration", destination: URL(string: "https://wetrakr.com/profile/settings/api")!)
                    .modifier(PointingHandCursor())
                    .font(.caption)
            }
            if let error = store.connectionError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .tint(AppStyle.accent)
        .frame(width: 400, alignment: .leading)
        .padding(.vertical, 14)
        .onDisappear { store.cancelConnection() }
        .onChange(of: store.isConnected) { _, _ in
            if isSheet { dismiss() }
        }
    }
}

private struct ConnectionActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(isHovering || configuration.isPressed ?
                            Color(red: 0.21, green: 0.22, blue: 0.25) : AppStyle.surface,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .opacity(configuration.isPressed ? 0.85 : 1)
                .onHover { isHovering = $0 }
        }
    }
}