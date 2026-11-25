import AVFoundation
import SwiftUI

@main
struct MyVoiceApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView().onAppear { TapOutsideToDismiss.install() }
        }
    }
}

/// 文字の欄の外をタップしたら、キーボードを閉じる。
final class TapOutsideToDismiss: NSObject, UIGestureRecognizerDelegate {
    private static let shared = TapOutsideToDismiss()

    static func install() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === shared }) {
            let tap = UITapGestureRecognizer(target: shared, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = shared
            window.addGestureRecognizer(tap)
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        tap.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

struct ContentView: View {
    @State private var micGranted = AVAudioApplication.shared.recordPermission == .granted
    @State private var apiKey = ""
    @State private var changingKey = false
    @State private var confirmChangeKey = false
    @State private var keySaved = APIKeyStore.load() != nil
    @State private var terms = TermStore.load()
    @State private var newWrong = ""
    @State private var newRight = ""
    @State private var testText = ""
    @State private var usage = UsageStore.thisMonth()
    @State private var modes = ModeStore.load()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("準備") {
                    HStack {
                        Label("マイク", systemImage: micGranted ? "checkmark.circle.fill" : "mic")
                        Spacer()
                        if micGranted {
                            Text("許可済み").foregroundStyle(.secondary)
                        } else {
                            Button("許可する") { requestMic() }
                        }
                    }
                    if keySaved && !changingKey {
                        // 保存済みのキーは表示だけにして、うっかり消さないようにする
                        HStack {
                            Label("Groq APIキー", systemImage: "checkmark.circle.fill")
                            Spacer()
                            Text("保存済み(…\(String((APIKeyStore.load() ?? "").suffix(4))))")
                                .foregroundStyle(.secondary)
                        }
                        Button("キーを変更する") { confirmChangeKey = true }
                            .font(.footnote)
                            .confirmationDialog("APIキーを変更しますか？", isPresented: $confirmChangeKey, titleVisibility: .visible) {
                                Button("新しいキーを入力する") {
                                    apiKey = ""
                                    changingKey = true
                                }
                            } message: {
                                Text("新しいキーを保存するまで、今のキーはそのまま使えます。")
                            }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Groq APIキー", systemImage: "key")
                            SecureField("gsk_...", text: $apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            HStack {
                                Button("保存") {
                                    keySaved = APIKeyStore.save(apiKey) && APIKeyStore.load() != nil
                                    if keySaved { changingKey = false; apiKey = "" }
                                }
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if changingKey {
                                    Spacer()
                                    Button("やめる", role: .cancel) {
                                        changingKey = false
                                        apiKey = ""
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("キーボードを追加", systemImage: "keyboard")
                        Text("設定 → 一般 → キーボード → キーボード → 新しいキーボードを追加 → マイ音声入力。そのあと「マイ音声入力」を開いて「フルアクセスを許可」をオンにします。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("このアプリの設定を開く") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                Section {
                    TextField("試しに入力(地球儀キーで切り替え)", text: $testText, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("試す")
                }

                Section {
                    ForEach($modes) { $mode in
                        NavigationLink {
                            ModeEditor(mode: $mode) { ModeStore.save(modes) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.name)
                                Text(mode.usesAI ? mode.instruction : "整形せずにそのまま入れる")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onDelete { offsets in
                        modes.remove(atOffsets: offsets)
                        if modes.isEmpty { modes = ModeStore.defaults }
                        ModeStore.save(modes)
                    }
                    .onMove { from, to in
                        modes.move(fromOffsets: from, toOffset: to)
                        ModeStore.save(modes)
                    }
                    Button("モードを追加") {
                        modes.append(FormatMode(name: "新しいモード", instruction: "話した内容を〇〇に整えてください。"))
                        ModeStore.save(modes)
                    }
                    Button("最初の状態に戻す", role: .destructive) {
                        modes = ModeStore.defaults
                        ModeStore.save(modes)
                    }
                } header: {
                    Text("整形モード")
                } footer: {
                    Text("キーボードの上の段で選びます。指示が空のモードは整形しません。整形にはGroqの\(TextFormatter.model)を使います(無料枠あり)。")
                }

                Section {
                    let hints = Set(TermStore.hintWords(terms))
                    ForEach(terms) { term in
                        HStack {
                            Text(term.wrong.isEmpty ? "(置き換えなし)" : term.wrong)
                                .foregroundStyle(term.wrong.isEmpty ? .secondary : .primary)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(term.right).bold()
                            Spacer()
                            if hints.contains(term.right) {
                                Text("ヒント")
                                    .font(.caption2).bold()
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .onDelete { offsets in
                        terms.remove(atOffsets: offsets)
                        TermStore.save(terms)
                    }
                    .onMove { from, to in
                        terms.move(fromOffsets: from, toOffset: to)
                        TermStore.save(terms)
                    }
                    NavigationLink {
                        ImportView(terms: $terms)
                    } label: {
                        Label("AIのメモリから取り込む", systemImage: "square.and.arrow.down")
                    }
                    HStack {
                        TextField("誤変換", text: $newWrong)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("正しい表記", text: $newRight)
                        Button {
                            terms.append(Term(wrong: newWrong.trimmingCharacters(in: .whitespaces),
                                              right: newRight.trimmingCharacters(in: .whitespaces)))
                            TermStore.save(terms)
                            newWrong = ""
                            newRight = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newRight.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("用語辞書")
                } footer: {
                    Text("""
                    実際に出た誤変換を左に書くと、自動で右に置き換えます。置き換えと整形モードは、辞書のすべての語に効きます。

                    【上にある語ほど優先されます】Groqの仕様で、認識のヒントとして一緒に送れる文字数には上限があります(224トークン)。送れるのは辞書の上から「ヒント」の印が付いている語までで、それより下の語はヒントになりません。よく使う語・間違えられやすい語ほど上に置いてください。右上の「編集」で並べ替えられます。
                    """)
                }

                Section {
                    LabeledContent("回数", value: "\(Int(usage.count))回")
                    LabeledContent("録音した時間", value: String(format: "%.1f分", usage.seconds / 60))
                    LabeledContent("料金の目安", value: String(format: "約%.0f円", UsageStore.estimatedYen(billedSeconds: usage.billedSeconds)))
                } header: {
                    Text("今月の使用量")
                } footer: {
                    Text("Whisper Large v3 Turbo($0.04/時間、1回最低10秒、1ドル150円)で計算。無料枠の中なら実際は0円です。")
                }
            }
            .navigationTitle("マイ音声入力")
            .scrollDismissesKeyboard(.immediately)
            .toolbar { EditButton() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micGranted = AVAudioApplication.shared.recordPermission == .granted
            usage = UsageStore.thisMonth()
            modes = ModeStore.load()
            terms = TermStore.load()
        }
    }

    private func requestMic() {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }
}
