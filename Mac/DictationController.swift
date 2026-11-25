import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Caps Lock(KarabinerでF18)を押している間だけ録音し、離したら文字にして、前面のアプリのカーソル位置に入れる。
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(Date)
        case processing(String)
        case message(String)
    }

    static let shared = DictationController()

    /// F18のキーコード(kVK_F18)
    private static let hotKeyCode: UInt16 = 79
    /// Codex(ChatGPT.app)。設定をオンにしたときだけ、前面にあるCodexには反応しない
    /// (2026-11-25、本人の許可でCodex側のF18の割り当ては外した)
    private static let codexBundleID = "com.openai.codex"
    /// これより短い押下は、押し間違いとして捨てる
    private static let minimumSeconds = 0.4

    @Published private(set) var phase: Phase = .idle
    @Published var modes = ModeStore.load()
    @Published var selectedModeID = ModeStore.selected(in: ModeStore.load()).id
    @Published var language = SpeechLanguage.current {
        didSet { SpeechLanguage.current = language }
    }
    @AppStorage("leaveF18ToCodex") var leaveF18ToCodex = false

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("myvoice-recording.wav") }
    private var monitors: [Any] = []
    private var keyIsDown = false
    private let hud = HUDPanel()
    private var messageTask: Task<Void, Never>?

    var menuBarIcon: String {
        switch phase {
        case .recording: return "mic.fill"
        case .processing: return "ellipsis.circle"
        default: return "mic"
        }
    }

    // MARK: - 起動時

    func start() {
        requestPermissions()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == Self.hotKeyCode else { return }
            Task { @MainActor in self?.handleKey(down: event.type == .keyDown, isRepeat: event.isARepeat) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { event in
            handler(event)
            return event.keyCode == Self.hotKeyCode ? nil : event
        }) {
            monitors.append(local)
        }
    }

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var hasMicrophone: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func reloadSettings() {
        modes = ModeStore.load()
        selectedModeID = ModeStore.selected(in: modes).id
    }

    func select(_ mode: FormatMode) {
        ModeStore.select(mode)
        selectedModeID = mode.id
    }

    // MARK: - キー

    private func handleKey(down: Bool, isRepeat: Bool) {
        if down {
            guard !isRepeat, !keyIsDown else { return }
            keyIsDown = true
            if leaveF18ToCodex, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.codexBundleID { return }
            startRecording()
        } else {
            guard keyIsDown else { return }
            keyIsDown = false
            stopRecording()
        }
    }

    // MARK: - 録音

    private func startRecording() {
        if case .message = phase { messageTask?.cancel(); phase = .idle }
        guard case .idle = phase else { return }
        guard hasMicrophone else { return show("マイクが許可されていません。システム設定で許可してください") }
        guard APIKeyStore.load() != nil else { return show(GroqError.noAPIKey.errorDescription ?? "") }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            try? FileManager.default.removeItem(at: recordingURL)
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            guard recorder.record() else { return show("録音を始められませんでした") }
            self.recorder = recorder
            NSSound(named: "Tink")?.play()
            set(.recording(Date()))
        } catch {
            show("録音を始められませんでした: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard case let .recording(startedAt) = phase, let recorder else { return }
        let seconds = Date().timeIntervalSince(startedAt)
        recorder.stop()
        self.recorder = nil
        guard seconds >= Self.minimumSeconds else { set(.idle); return }
        NSSound(named: "Pop")?.play()
        guard let wav = try? Data(contentsOf: recordingURL) else { return show("録音ファイルを読めませんでした") }
        transcribe(wav: wav, seconds: seconds)
    }

    // MARK: - 文字起こし → 整形 → 入力

    private func transcribe(wav: Data, seconds: Double) {
        guard let apiKey = APIKeyStore.load() else { return show(GroqError.noAPIKey.errorDescription ?? "") }
        let terms = TermStore.load()
        let language = SpeechLanguage.current
        let mode = modes.first { $0.id == selectedModeID } ?? modes[0]
        set(.processing("文字にしています…"))
        Task { @MainActor in
            do {
                let raw = try await GroqClient.transcribe(wav: wav, apiKey: apiKey, prompt: TermStore.prompt(for: terms, language: language), language: language)
                UsageStore.add(seconds: seconds)
                let text = TermStore.apply(terms, to: GroqClient.clean(raw))
                guard !text.isEmpty else { return show("声が聞き取れませんでした") }
                guard mode.usesAI else {
                    insert(text)
                    return set(.idle)
                }
                set(.processing("「\(mode.name)」で整えています…"))
                do {
                    let formatted = try await TextFormatter.format(text, mode: mode, terms: terms, apiKey: apiKey)
                    insert(formatted.isEmpty ? text : TermStore.apply(terms, to: formatted))
                    set(.idle)
                } catch {
                    // 整形に失敗しても、話した言葉は失わない
                    insert(text)
                    show("整形できなかったので、そのまま入れました")
                }
            } catch {
                show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// クリップボード経由で ⌘V を送り、少し待ってから元のクリップボードに戻す。
    private func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChange = pasteboard.changeCount

        guard hasAccessibility else {
            return show("アクセシビリティが未許可なので、クリップボードにコピーしました。⌘Vで貼ってください")
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            // その間にほかでコピーされていなければ、元に戻す
            guard pasteboard.changeCount == ourChange, let previous else { return }
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }
    }

    // MARK: - 表示

    private func set(_ newPhase: Phase) {
        messageTask?.cancel()
        phase = newPhase
        hud.update(phase: newPhase)
    }

    private func show(_ message: String) {
        set(.message(message))
        messageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, case .message = phase else { return }
            set(.idle)
        }
    }
}
