import AppKit
import QuartzCore

/// Native selection/accessibility with a small, non-interactive hover overlay.
/// Core Animation owns the brief transitions: no timers, polling or idle redraws.
final class HoverSegmentedControl: NSSegmentedControl {
    private let highlight = CALayer()
    private var hoverTracking: NSTrackingArea?
    private(set) var hoveredSegment: Int?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) { super.init(frame: frame); configureHover() }
    required init?(coder: NSCoder) { super.init(coder: coder); configureHover() }

    private func configureHover() {
        segmentDistribution = .fillEqually
        wantsLayer = true
        highlight.name = "MyBar.segmentHover"
        highlight.zPosition = 1
        highlight.cornerRadius = 5
        highlight.borderWidth = 0.5
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        refreshHoverColors()
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { updateHover(at: nil, animated: false) } }
    }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); hoverTracking = tracking
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { updateHover(at: nil) }
    override func viewDidHide() { super.viewDidHide(); updateHover(at: nil, animated: false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { updateHover(at: nil, animated: false) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshHoverColors() }
    override func layout() {
        super.layout()
        if let index = hoveredSegment {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            highlight.frame = segmentFrame(index)
            CATransaction.commit()
        }
    }

    private func refreshHoverColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            highlight.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            CATransaction.commit()
        }
    }
    private func segmentFrame(_ index: Int) -> NSRect {
        let content = bounds.insetBy(dx: 2, dy: 2)
        let width = content.width / CGFloat(max(1, segmentCount))
        return NSRect(x: content.minX + CGFloat(index) * width, y: content.minY, width: width, height: content.height)
    }

    func updateHover(at point: NSPoint?, animated: Bool = true) {
        var index: Int?
        if isEnabled, !isHiddenOrHasHiddenAncestor, segmentCount > 0, bounds.width > 4, bounds.height > 4,
           let point, bounds.insetBy(dx: 2, dy: 2).contains(point) {
            let candidate = min(segmentCount - 1, max(0, Int((point.x - 2) / ((bounds.width - 4) / CGFloat(segmentCount)))))
            if isEnabled(forSegment: candidate) { index = candidate }
        }
        let animate = animated && !reduceMotion()
        if !animate { highlight.removeAllAnimations() }
        guard index != hoveredSegment else { return }
        let wasVisible = hoveredSegment != nil
        let oldPosition = highlight.presentation()?.position ?? highlight.position
        let oldOpacity = highlight.presentation()?.opacity ?? highlight.opacity
        hoveredSegment = index
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let index { highlight.frame = segmentFrame(index) }
        highlight.opacity = index == nil ? 0 : 1
        CATransaction.commit()
        guard animate else { return }
        if wasVisible, index != nil, oldPosition != highlight.position {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: oldPosition); slide.toValue = NSValue(point: highlight.position)
            slide.duration = 0.14; slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlight.add(slide, forKey: "hoverPosition")
        }
        if oldOpacity != highlight.opacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity; fade.toValue = highlight.opacity
            fade.duration = 0.12; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlight.add(fade, forKey: "hoverOpacity")
        }
    }
}
