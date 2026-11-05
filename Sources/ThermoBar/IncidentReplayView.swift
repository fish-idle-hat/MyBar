import AppKit

final class IncidentReplayView: NSView {
    private let points: [IncidentMetricPoint]
    private let startedAt: Date
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let play = NSButton(title: "Replay", target: nil, action: nil)
    private var timer: Timer?
    private var position = 0

    override var isFlipped: Bool { true }

    init(incident: MonitoringIncident) {
        startedAt = incident.startedAt
        points = incident.points.filter { abs($0.timestamp.timeIntervalSince(incident.startedAt)) <= 60 }
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 240))
        slider.frame = NSRect(x: 20, y: 202, width: 340, height: 22)
        slider.maxValue = Double(max(0, points.count - 1))
        slider.target = self
        slider.action = #selector(scrub)
        slider.setAccessibilityLabel("Incident time")
        play.frame = NSRect(x: 373, y: 200, width: 78, height: 26)
        play.target = self
        play.action = #selector(replay)
        addSubview(slider)
        addSubview(play)
    }

    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        play.title = "Replay"
    }

    @objc private func scrub() {
        stop()
        position = slider.integerValue
        needsDisplay = true
    }

    @objc private func replay() {
        if timer != nil { stop(); return }
        guard points.count > 1 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            position = points.count - 1
            slider.integerValue = position
            needsDisplay = true
            return
        }
        position = 0
        play.title = "Pause"
        let timer = Timer(timeInterval: max(0.05, 5 / Double(points.count)), repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.window?.isVisible == true else { self.stop(); return }
            self.position = min(self.position + 1, self.points.count - 1)
            self.slider.integerValue = self.position
            self.needsDisplay = true
            if self.position == self.points.count - 1 { self.stop() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        func text(_ string: String, _ rect: NSRect, size: CGFloat = 11, color: NSColor = .labelColor) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style,
            ]).draw(in: rect)
        }
        text("Cause Chain Replay", NSRect(x: 20, y: 14, width: 400, height: 22), size: 15)
        text("Correlated activity; the app shown is a candidate, not a proven cause.", NSRect(x: 20, y: 41, width: 430, height: 18), size: 10, color: .secondaryLabelColor)
        guard !points.isEmpty else { return }
        let point = points[min(position, points.count - 1)]
        let values = [point.appName ?? "Unavailable", point.chipWatts.map { String(format: "%.1f W", $0) } ?? "—",
                      point.temperature.map { String(format: "%.0f°C", $0) } ?? "—",
                      point.fanRPM.map { String(format: "%.0f RPM", $0) } ?? "—"]
        for (i, title) in ["APP", "CHIP POWER", "TEMPERATURE", "FANS"].enumerated() {
            let x = CGFloat(20 + i * 112)
            let rect = NSRect(x: x, y: 76, width: 100, height: 58)
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            text(title, NSRect(x: x + 7, y: 84, width: 88, height: 15), size: 9, color: .secondaryLabelColor)
            text(values[i], NSRect(x: x + 7, y: 108, width: 88, height: 18), size: 11)
            if i < 3 {
                let progress = CGFloat(position) / CGFloat(max(1, points.count - 1))
                (progress >= CGFloat(i + 1) / 4 ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
                NSRect(x: x + 101, y: 104, width: 10, height: 2).fill()
            }
        }
        // Synchronized temperature trace and a moving time marker.
        let graph = NSRect(x: 20, y: 151, width: 430, height: 34)
        let temperatures = points.compactMap(\.temperature)
        if let low = temperatures.min(), let high = temperatures.max() {
            let path = NSBezierPath()
            var hasPoint = false
            for (i, sample) in points.enumerated() {
                guard let value = sample.temperature else { hasPoint = false; continue }
                let p = NSPoint(x: graph.minX + CGFloat(i) / CGFloat(max(1, points.count - 1)) * graph.width,
                                y: graph.maxY - CGFloat((value - low) / max(1, high - low)) * graph.height)
                if hasPoint { path.line(to: p) } else { path.move(to: p); hasPoint = true }
            }
            NSColor.systemOrange.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
        let markerX = graph.minX + CGFloat(position) / CGFloat(max(1, points.count - 1)) * graph.width
        NSColor.controlAccentColor.setFill()
        NSRect(x: markerX, y: graph.minY, width: 1, height: graph.height).fill()
        text(String(format: "%+.0f seconds from alert", point.timestamp.timeIntervalSince(startedAt)),
             NSRect(x: 20, y: 225, width: 350, height: 14), size: 9, color: .secondaryLabelColor)
    }
}
