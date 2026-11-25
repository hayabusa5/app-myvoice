import SwiftUI

/// ClaudeやChatGPTのメモリから書き出した用語を、コピー&貼り付けで辞書に取り込む。
struct ImportView: View {
    @Binding var terms: [Term]
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var candidates: [Term] = []
    @State private var excluded = Set<UUID>()
    @State private var copied = false
    @State private var copiedLatest = false

    private var selectedCount: Int { candidates.filter { !excluded.contains($0.id) }.count }

    var body: some View {
        Form {
            Section {
                Button {
                    UIPasteboard.general.string = TermImport.prompt
                    copied = true
                } label: {
                    Label(copied ? "コピーしました" : "AIに頼む文をコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.string = TermImport.latestPrompt
                    copiedLatest = true
                } label: {
                    Label(copiedLatest ? "コピーしました" : "新しいAIツール名を頼む文をコピー", systemImage: copiedLatest ? "checkmark" : "magnifyingglass")
                }
                DisclosureGroup("頼む文の中身") {
                    Text(TermImport.prompt).font(.footnote).foregroundStyle(.secondary)
                    Text(TermImport.latestPrompt).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("1. ClaudeやChatGPTに頼む")
            } footer: {
                Text("上の文はメモリがオンのClaudeやChatGPTに、下の文はWeb検索をオンにしたClaudeやChatGPTに貼って送ります。自分のメモやObsidianのノートを貼って「この中から」と頼んでも使えます。")
            }

            Section {
                Button {
                    pasted = UIPasteboard.general.string ?? ""
                    readPasted()
                } label: {
                    Label("AIの返事を貼り付けて読み込む", systemImage: "doc.on.clipboard")
                }
                TextField("ここに直接貼ってもかまいません", text: $pasted, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: pasted) { _, _ in readPasted() }
            } header: {
                Text("2. 返事をコピーして貼る")
            }

            if !pasted.isEmpty {
                Section {
                    if candidates.isEmpty {
                        Text("新しく追加できる語は見つかりませんでした。すでに登録済みか、形式が違うかもしれません。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { term in
                        Button {
                            if excluded.contains(term.id) { excluded.remove(term.id) } else { excluded.insert(term.id) }
                        } label: {
                            HStack {
                                Image(systemName: excluded.contains(term.id) ? "circle" : "checkmark.circle.fill")
                                    .foregroundStyle(excluded.contains(term.id) ? Color.secondary : Color.accentColor)
                                Text(term.wrong.isEmpty ? "(ヒントのみ)" : term.wrong)
                                    .foregroundStyle(term.wrong.isEmpty ? .secondary : .primary)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(term.right).bold()
                            }
                        }
                        .tint(.primary)
                    }
                } header: {
                    Text("3. 確認して追加(\(candidates.count)件)")
                } footer: {
                    Text("要らない語は、タップしてチェックを外します。すでに辞書にある語は出していません。")
                }
            }
        }
        .navigationTitle("辞書をインポート")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("\(selectedCount)件を追加") {
                    terms.append(contentsOf: candidates.filter { !excluded.contains($0.id) })
                    TermStore.save(terms)
                    dismiss()
                }
                .disabled(selectedCount == 0)
            }
        }
    }

    private func readPasted() {
        candidates = TermImport.newTerms(TermImport.parse(pasted), existing: terms)
        excluded = []
    }
}
