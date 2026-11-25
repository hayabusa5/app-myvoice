import UIKit

/// 録音中の声の大きさを、右から流れる棒で見せる。
final class WaveformView: UIView {
    private var levels: [CGFloat] = []
    private var pendingPeak: Float = 0
    private var lastPush = Date.distantPast
    /// 棒1本の間隔(秒)
    private let interval: TimeInterval = 0.05
    var barColor: UIColor = .white

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        levels = []
        pendingPeak = 0
        lastPush = .distantPast
        setNeedsDisplay()
    }

    /// 届いた音の大きさ(RMS、0〜1)を足す
    func push(rms: Float) {
        pendingPeak = max(pendingPeak, rms)
        let now = Date()
        guard now.timeIntervalSince(lastPush) >= interval else { return }
        lastPush = now
        levels.append(Self.normalize(pendingPeak))
        pendingPeak = 0
        let maxCount = Int(bounds.width / 5) + 1
        if levels.count > maxCount { levels.removeFirst(levels.count - maxCount) }
        setNeedsDisplay()
    }

    /// 小さな声も見えるように、デシベルで0〜1にならす
    static func normalize(_ rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return CGFloat(min(max((db + 55) / 45, 0), 1))
    }

    override func draw(_ rect: CGRect) {
        let barWidth: CGFloat = 3
        let step: CGFloat = 5
        let midY = bounds.midY
        let maxHeight = bounds.height
        barColor.setFill()
        // 右端が最新。足りない分は小さな点で埋める
        let count = Int(bounds.width / step)
        for i in 0..<count {
            let index = levels.count - count + i
            let level = index >= 0 ? levels[index] : 0
            let height = max(barWidth, level * maxHeight)
            let x = CGFloat(i) * step + (bounds.width - CGFloat(count) * step) / 2
            let bar = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
            UIBezierPath(roundedRect: bar, cornerRadius: barWidth / 2).fill()
        }
    }
}
