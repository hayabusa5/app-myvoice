import SwiftUI

@main
struct MyVoiceMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = DictationController.shared

    var body: some Scene {
        MenuBarExtra("マイ音声入力", systemImage: controller.menuBarIcon) {
            MenuContent(controller: controller)
        }
        .menuBarExtraStyle(.menu)

        Window("マイ音声入力の設定", id: "settings") {
            MacSettingsView()
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in DictationController.shared.start() }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)
        Divider()
        Text("Caps Lockを押している間だけ録音")
        Section("整形モード") {
            ForEach(controller.modes) { mode in
                Toggle(mode.name, isOn: Binding(
                    get: { controller.selectedModeID == mode.id },
                    set: { if $0 { controller.select(mode) } }
                ))
            }
        }
        Divider()
        Button("設定…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return "待機中"
        case .recording: return "録音中…"
        case let .processing(text): return text
        case let .message(text): return text
        }
    }
}
