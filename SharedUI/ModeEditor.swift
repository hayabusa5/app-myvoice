import SwiftUI

/// 整形モードの名前と指示を編集する(iPhone・Mac共通)
struct ModeEditor: View {
    @Binding var mode: FormatMode
    var onSave: () -> Void

    var body: some View {
        Form {
            Section("名前") {
                TextField("名前", text: $mode.name)
            }
            Section {
                TextField("AIへの指示", text: $mode.instruction, axis: .vertical)
                    .lineLimit(4...12)
            } header: {
                Text("AIへの指示")
            } footer: {
                Text("空にすると、整形せずにそのまま入れます。")
            }
        }
        .navigationTitle(mode.name)
        #if os(iOS)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .onDisappear(perform: onSave)
    }
}
