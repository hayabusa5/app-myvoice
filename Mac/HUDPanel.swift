import AppKit
import SwiftUI

/// 画面の下に出る小さな表示(録音中・処理中・メッセージ)。前面のアプリからフォーカスを奪わない。
@MainActor
final class HUDPanel {
    private let model = HUDModel()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }()

    func update(phase: DictationController.Phase) {
        switch phase {
        case .idle:
            panel.orderOut(nil)
            return
        case let .recording(startedAt):
            model.text = "録音中"
            model.startedAt = startedAt
            model.color = .red
        case let .processing(text):
            model.text = text
            model.startedAt = nil
            model.color = .accentColor
        case let .message(text):
            model.text = text
            model.startedAt = nil
            model.color = .orange
        }
        position()
        panel.orderFrontRegardless()
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 60))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var startedAt: Date?
    @Published var color: Color = .red
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.color).frame(width: 10, height: 10)
            if let startedAt = model.startedAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(String(format: "%@ %.1f秒", model.text, context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
            } else {
                Text(model.text).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.78), in: Capsule())
    }
}
