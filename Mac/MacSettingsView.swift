import SwiftUI

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("一般", systemImage: "gearshape") }
            NavigationStack { DictionaryTab() }.tabItem { Label("用語辞書", systemImage: "character.book.closed") }
            NavigationStack { ModesTab() }.tabItem { Label("整形モード", systemImage: "text.badge.star") }
        }
        .padding()
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

// MARK: - 一般

private struct GeneralTab: View {
    @ObservedObject private var controller = DictationController.shared
    @State private var keySaved = APIKeyStore.load() != nil
    @State private var changingKey = false
    @State private var apiKey = ""
    @State private var usage = UsageStore.thisMonth()
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("使い方") {
                Text("Caps Lockを押している間だけ録音します。離すと文字にして、今カーソルがある場所に入れます。")
                Toggle("Codexが前面のときは、Codexの音声入力に任せる", isOn: $controller.leaveF18ToCodex)
            }

            Section("Groq APIキー") {
                if keySaved && !changingKey {
                    // 保存済みのキーは表示だけにして、うっかり消さないようにする
                    LabeledContent("保存済み", value: "…" + String((APIKeyStore.load() ?? "").suffix(4)))
                    Button("キーを変更する") { apiKey = ""; changingKey = true }
                } else {
                    SecureField("gsk_...", text: $apiKey)
                    HStack {
                        Button("保存") {
                            keySaved = APIKeyStore.save(apiKey) && APIKeyStore.load() != nil
                            if keySaved { changingKey = false; apiKey = "" }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if changingKey { Button("やめる") { changingKey = false; apiKey = "" } }
                        Spacer()
                        Link("キーを発行する", destination: URL(string: "https://console.groq.com/keys")!)
                    }
                }
            }

            Section("許可") {
                permissionRow("マイク", granted: controller.hasMicrophone,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                permissionRow("アクセシビリティ(カーソル位置に入れるため)", granted: controller.hasAccessibility,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                Button("表示を更新") { refresh += 1 }
            }
            .id(refresh)

            Section {
                LabeledContent("回数", value: "\(Int(usage.count))回")
                LabeledContent("録音した時間", value: String(format: "%.1f分", usage.seconds / 60))
                LabeledContent("料金の目安", value: String(format: "約%.0f円", UsageStore.estimatedYen(billedSeconds: usage.billedSeconds)))
            } header: {
                Text("今月の使用量(このMac)")
            } footer: {
                Text("Whisper Large v3 Turbo($0.04/時間、1回最低10秒、1ドル150円)で計算。無料枠の中なら実際は0円です。")
            }
        }
        .formStyle(.grouped)
        .onAppear { usage = UsageStore.thisMonth() }
    }

    private func permissionRow(_ title: String, granted: Bool, url: String) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.primary : Color.orange)
            Spacer()
            if !granted {
                Button("システム設定を開く") { NSWorkspace.shared.open(URL(string: url)!) }
            }
        }
    }
}

// MARK: - 用語辞書

private struct DictionaryTab: View {
    @State private var terms = TermStore.load()
    @State private var newWrong = ""
    @State private var newRight = ""

    var body: some View {
        let hints = Set(TermStore.hintWords(terms))
        Form {
            Section {
                HStack {
                    TextField("誤変換", text: $newWrong)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("正しい表記", text: $newRight)
                    Button("追加") {
                        terms.insert(Term(wrong: newWrong.trimmingCharacters(in: .whitespaces),
                                          right: newRight.trimmingCharacters(in: .whitespaces)), at: 0)
                        TermStore.save(terms)
                        newWrong = ""
                        newRight = ""
                    }
                    .disabled(newRight.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                NavigationLink("AIのメモリから取り込む") { ImportView(terms: $terms).formStyle(.grouped) }
            }

            Section {
                List {
                    ForEach(terms) { term in
                        HStack {
                            Text(term.wrong.isEmpty ? "(置き換えなし)" : term.wrong)
                                .foregroundStyle(term.wrong.isEmpty ? .secondary : .primary)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(term.right).bold()
                            Spacer()
                            if hints.contains(term.right) {
                                Text("ヒント").font(.caption2).bold().foregroundStyle(Color.accentColor)
                            }
                            Button {
                                terms.removeAll { $0.id == term.id }
                                TermStore.save(terms)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove { from, to in
                        terms.move(fromOffsets: from, toOffset: to)
                        TermStore.save(terms)
                    }
                }
            } header: {
                Text("登録済み(\(terms.count)語)")
            } footer: {
                Text("【上にある語ほど優先されます】Groqの仕様で、認識のヒントとして送れる文字数には上限があります(224トークン)。送れるのは上から「ヒント」の印が付いた語までです。行をドラッグして並べ替えられます。置き換えと整形モードは、すべての語に効きます。このMacの辞書は、iPhoneの辞書とはまだ同期しません。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("用語辞書")
    }
}

// MARK: - 整形モード

private struct ModesTab: View {
    @State private var modes = ModeStore.load()

    var body: some View {
        Form {
            Section {
                List {
                    ForEach($modes) { $mode in
                        NavigationLink {
                            ModeEditor(mode: $mode) { save() }.formStyle(.grouped)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(mode.name)
                                Text(mode.usesAI ? mode.instruction : "整形せずにそのまま入れる")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .onMove { from, to in
                        modes.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                }
            } footer: {
                Text("メニューバーのマイクのアイコンから選びます。行をドラッグして並べ替えられます。")
            }
            Section {
                Button("モードを追加") {
                    modes.append(FormatMode(name: "新しいモード", instruction: "話した内容を〇〇に整えてください。"))
                    save()
                }
                Button("最初の状態に戻す", role: .destructive) {
                    modes = ModeStore.defaults
                    save()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("整形モード")
    }

    private func save() {
        ModeStore.save(modes)
        DictationController.shared.reloadSettings()
    }
}
