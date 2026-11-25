import ServiceManagement
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
        // 初めて起動したときに、ログイン時に自動で起動するよう登録する(メニューで外せる)
        if !UserDefaults.standard.bool(forKey: "login-item-asked") {
            UserDefaults.standard.set(true, forKey: "login-item-asked")
            try? SMAppService.mainApp.register()
        }
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
        Section("マイク(今: \(controller.currentInput?.name ?? "不明"))") {
            Toggle("システムの入力に従う", isOn: Binding(
                get: { controller.preferredInputUID == nil },
                set: { if $0 { controller.preferredInputUID = nil } }
            ))
            ForEach(controller.inputDevices) { device in
                Toggle(device.name, isOn: Binding(
                    get: { controller.preferredInputUID == device.uid },
                    set: { if $0 { controller.preferredInputUID = device.uid } }
                ))
            }
        }
        .onAppear { controller.refreshInputs() }
        Section("認識する言語") {
            ForEach(SpeechLanguage.allCases) { language in
                Toggle(language.label, isOn: Binding(
                    get: { controller.language == language },
                    set: { if $0 { controller.language = language } }
                ))
            }
        }
        Section("整形モード") {
            ForEach(controller.modes) { mode in
                Toggle(mode.name, isOn: Binding(
                    get: { controller.selectedModeID == mode.id },
                    set: { if $0 { controller.select(mode) } }
                ))
            }
        }
        Divider()
        Toggle("Macの起動時に開く", isOn: Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
        ))
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
