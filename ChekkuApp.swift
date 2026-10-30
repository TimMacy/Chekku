import AppKit
import SwiftUI

@main
@MainActor
struct ChekkuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: UpNextStore

    init() {
        _store = StateObject(wrappedValue: UpNextStore())
    }

    var body: some Scene {
        Window("Chekku", id: "up-next") {
            UpNextView(store: store)
                .tint(AppStyle.accent)
        }
        .defaultSize(width: 1160, height: 430)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Chekku") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        NSApplication.AboutPanelOptionKey(rawValue: "ApplicationName"): "チェック 〜 Chekku",
                        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): ""
                    ])
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
