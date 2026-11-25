import AppKit
import SwiftUI

/// 画面の下に出る小さな表示(録音中・処理中・メッセージ)。前面のアプリからフォーカスを奪わない。
@MainActor
final class HUDPanel {
    private let model = HUDModel()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 84),
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

    func resetLevels() { model.levels = [] }

    /// 録音に使うマイクの名前(HUDに出す)
    var micName: String? {
        get { model.micName }
        set { model.micName = newValue }
    }

    /// 録音の音量(dB、-160〜0)を波形に足す
    func push(decibels: Float) {
        let level = CGFloat(min(max((decibels + 50) / 45, 0), 1))
        model.levels.append(level)
        if model.levels.count > HUDModel.maxBars { model.levels.removeFirst(model.levels.count - HUDModel.maxBars) }
    }

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
    @Published var levels: [CGFloat] = []
    @Published var micName: String?
    static let maxBars = 36
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        // 上の吹き出し: 録音中のマイク名。下の吹き出し: 状態・波形・秒数
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if model.startedAt != nil, let micName = model.micName {
                micBubble(micName)
            }
            mainBubble.frame(height: 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func micBubble(_ name: String) -> some View {
        // AirPodsで録っているときは、音質が落ちるのでオレンジで目立たせる
        let isAirPods = name.localizedCaseInsensitiveContains("airpods")
        return Label(name, systemImage: isAirPods ? "airpods" : "mic.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isAirPods ? Color.black : Color.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isAirPods ? Color.orange : Color.black.opacity(0.78), in: Capsule())
    }

    private var mainBubble: some View {
        HStack(spacing: 8) {
            Circle().fill(model.color).frame(width: 10, height: 10)
            if let startedAt = model.startedAt {
                WaveformBars(levels: model.levels)
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(String(format: "%.1f秒", context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
                .frame(width: 52, alignment: .trailing)
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

/// 右から流れる棒の波形。右端が最新
private struct WaveformBars: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<HUDModel.maxBars, id: \.self) { i in
                let index = levels.count - HUDModel.maxBars + i
                let level = index >= 0 ? levels[index] : 0
                Capsule()
                    .frame(width: 3, height: max(3, level * 24))
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
