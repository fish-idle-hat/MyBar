import AppKit
import QuartzCore

final class PetSpriteAtlas {
    static let shared = PetSpriteAtlas()
    let idle: [CGImage]
    let working: [CGImage]
    var isAvailable: Bool { idle.count == 6 && working.count == 6 }

    private init() {
        // SwiftPM's generated accessor looks beside an .app, not inside its
        // Resources folder, and can fatalError. Resolve the installed asset
        // explicitly; use Bundle.module only in the SwiftPM test/CLI layout.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("ThermoBar_ThermoBar.bundle/Pet/Capri.png")
        let url: URL?
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) { url = packaged }
        else if Bundle.main.bundleURL.pathExtension != "app" {
            url = Bundle.module.url(forResource: "Capri", withExtension: "png", subdirectory: "Pet")
        } else { url = nil }
        guard let url,
              let image = NSImage(contentsOf: url),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width == 1536, source.height == 1872 else { idle = []; working = []; return }
        func frames(row: Int) -> [CGImage] {
            (0..<6).compactMap { column in
                guard let cropped = source.cropping(to: CGRect(x: column * 192 + 25, y: row * 208 + 50, width: 110, height: 145)),
                      let context = CGContext(data: nil, width: 110, height: 145, bitsPerComponent: 8, bytesPerRow: 440,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: 110, height: 145))
                // Copy each small frame so it doesn't retain the 11 MB atlas.
                return context.makeImage()
            }
        }
        idle = frames(row: 0); working = frames(row: 7)
    }
}

// All repeating animation is compositor-owned. No display link, per-frame
// Swift timer, web view, LLM, microphone capture or autonomous window movement.
final class PetCanvasView: NSView {
    static let canvasSize = NSSize(width: 320, height: 240)
    private let stage = CALayer()
    private let sprite = CALayer()
    private let screens = CALayer()
    private let headphones = CALayer()
    private let eyes = CALayer()
    private var bars: [CALayer] = []
    private(set) var activity = PetActivity()
    private(set) var animationsActive = false
    private var motionAllowed = true
    private var active = false
    var draggable = false
    override var isFlipped: Bool { true }

    override init(frame: NSRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }

    private func configure() {
        wantsLayer = true
        stage.bounds = CGRect(origin: .zero, size: Self.canvasSize)
        stage.anchorPoint = .zero
        stage.isGeometryFlipped = true
        layer?.addSublayer(stage)
        stage.addSublayer(screens)
        sprite.frame = CGRect(x: 94, y: 25, width: 132, height: 174)
        sprite.contentsGravity = .resizeAspect
        stage.addSublayer(sprite)
        stage.addSublayer(headphones); stage.addSublayer(eyes)
        buildScreens(); buildHeadphones(); buildEyes()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Capri desktop pet")
        update(PetActivity(), active: false, reduceMotion: false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = min(bounds.width / 320, bounds.height / 240)
        stage.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        stage.position = CGPoint(x: (bounds.width - 320 * scale) / 2, y: (bounds.height - 240 * scale) / 2)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        if draggable { addCursorRect(bounds, cursor: .openHand) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { draggable }
    override func mouseDown(with event: NSEvent) {
        guard draggable, let window else { super.mouseDown(with: event); return }
        // Native dragging captures the pointer even when it moves quickly
        // outside the transparent window. No custom mouse-event polling.
        window.performDrag(with: event)
    }

    func update(_ next: PetActivity, active: Bool, reduceMotion: Bool) {
        let animate = active && !reduceMotion
        guard next != activity || self.active != active || motionAllowed != !reduceMotion || sprite.contents == nil else { return }
        let putOnHeadphones = next.musicPlaying && !activity.musicPlaying
        activity = next; self.active = active; motionAllowed = !reduceMotion
        removeAnimations(stage)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let frames = next.codexWorking ? PetSpriteAtlas.shared.working : PetSpriteAtlas.shared.idle
        sprite.contents = frames.first
        screens.opacity = next.codexWorking ? 1 : 0
        headphones.opacity = next.musicPlaying ? 1 : 0
        eyes.opacity = next.fansSpinning ? 1 : 0
        let shift: CGFloat = next.codexWorking ? -18 : 0
        headphones.position = CGPoint(x: shift, y: 0)
        eyes.position = CGPoint(x: shift, y: 0)
        CATransaction.commit()
        animationsActive = animate
        setAccessibilityValue([next.codexWorking ? "Codex working" : "Codex idle",
            next.musicPlaying ? "Music playing" : "No music", next.fansSpinning ? "Fan eye effect on" : "Fans stopped"].joined(separator: ", "))
        guard animate else { return }
        if frames.count == 6 {
            let poses = CAKeyframeAnimation(keyPath: "contents")
            poses.values = frames
            poses.duration = next.codexWorking ? 0.94 : 1.1
            poses.calculationMode = .discrete
            poses.repeatCount = .infinity
            sprite.add(poses, forKey: "poses")
        }
        if next.codexWorking {
            for (index, bar) in bars.enumerated() {
                let progress = CABasicAnimation(keyPath: "transform.scale.x")
                progress.fromValue = 0.25; progress.toValue = 1
                progress.duration = 2.4; progress.autoreverses = true; progress.repeatCount = .infinity
                progress.timeOffset = Double(index) * 0.7
                bar.add(progress, forKey: "progress")
            }
        }
        if next.musicPlaying, putOnHeadphones {
            let lower = CABasicAnimation(keyPath: "position.y")
            lower.fromValue = 38; lower.toValue = 0; lower.duration = 0.55
            lower.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            headphones.add(lower, forKey: "putOn")
        }
        if next.fansSpinning {
            // Deliberately slow: no strobing or full-screen flashes.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.45; pulse.toValue = 1; pulse.duration = 0.9
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            eyes.add(pulse, forKey: "cyberPulse")
            let glitch = CAKeyframeAnimation(keyPath: "transform.translation.x")
            glitch.values = [0, 0, 1.2, -0.8, 0, 0]
            glitch.keyTimes = [0, 0.7, 0.73, 0.76, 0.8, 1]
            glitch.duration = 2.6; glitch.repeatCount = .infinity
            eyes.add(glitch, forKey: "cyberScan")
        }
    }

    private func removeAnimations(_ layer: CALayer) {
        layer.removeAllAnimations(); layer.sublayers?.forEach { removeAnimations($0) }
    }
    private func shape(_ path: CGPath, color: NSColor, fill: NSColor? = nil, width: CGFloat = 1) -> CAShapeLayer {
        let layer = CAShapeLayer(); layer.path = path; layer.strokeColor = color.cgColor
        layer.fillColor = fill?.cgColor; layer.lineWidth = width; layer.lineJoin = .round; layer.lineCap = .round
        return layer
    }
    private func text(_ value: String, at point: CGPoint, color: NSColor) -> CATextLayer {
        let layer = CATextLayer(); layer.string = value; layer.font = NSFont.monospacedSystemFont(ofSize: 7, weight: .medium)
        layer.fontSize = 7; layer.foregroundColor = color.cgColor; layer.contentsScale = 2
        layer.frame = CGRect(origin: point, size: CGSize(width: 80, height: 14)); return layer
    }
    private func buildScreens() {
        for (index, x) in [CGFloat(5), CGFloat(225)].enumerated() {
            let panel = CALayer(); panel.frame = CGRect(x: x, y: index == 0 ? 84 : 76, width: 90, height: 78)
            panel.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            panel.setAffineTransform(CGAffineTransform(rotationAngle: index == 0 ? -0.06 : 0.06))
            let outline = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 90, height: 78), cornerWidth: 5, cornerHeight: 5, transform: nil)
            panel.addSublayer(shape(outline, color: .systemTeal, fill: NSColor(calibratedRed: 0.015, green: 0.10, blue: 0.15, alpha: 0.90)))
            panel.addSublayer(text(index == 0 ? "NETRUN" : "SCANNING", at: CGPoint(x: 8, y: 55), color: .systemMint))
            for row in 0..<3 {
                panel.addSublayer(text(["INDEX 07", "LINK OK", "01 10 11"][row], at: CGPoint(x: 8, y: 39 - row * 10), color: .systemTeal))
            }
            let bar = CALayer(); bar.anchorPoint = .zero; bar.frame = CGRect(x: 8, y: 11, width: 73, height: 2)
            bar.backgroundColor = (index == 0 ? NSColor.systemMint : NSColor.systemCyan).cgColor
            panel.addSublayer(bar); bars.append(bar); screens.addSublayer(panel)
        }
    }
    private func buildHeadphones() {
        let arch = CGMutablePath()
        arch.move(to: CGPoint(x: 143, y: 138))
        arch.addCurve(to: CGPoint(x: 191, y: 144), control1: CGPoint(x: 133, y: 187), control2: CGPoint(x: 191, y: 195))
        headphones.addSublayer(shape(arch, color: NSColor(calibratedWhite: 0.045, alpha: 1), width: 8))
        headphones.addSublayer(shape(arch, color: .systemCyan, width: 1.5))
        for rect in [CGRect(x: 137, y: 122, width: 11, height: 23), CGRect(x: 187, y: 128, width: 11, height: 23)] {
            headphones.addSublayer(shape(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil),
                color: .systemCyan, fill: NSColor(calibratedWhite: 0.06, alpha: 1), width: 1.5))
        }
    }
    private func buildEyes() {
        for rect in [CGRect(x: 161, y: 124, width: 8, height: 4), CGRect(x: 173, y: 127, width: 8, height: 4)] {
            let eye = shape(CGPath(ellipseIn: rect, transform: nil), color: .systemMint, fill: .systemGreen, width: 1)
            eye.shadowColor = NSColor.systemGreen.cgColor; eye.shadowRadius = 4; eye.shadowOpacity = 0.9; eye.shadowOffset = .zero
            eyes.addSublayer(eye)
            eyes.addSublayer(shape(CGPath(ellipseIn: rect.insetBy(dx: 2.5, dy: 0.5), transform: nil), color: .black, fill: .black, width: 0.5))
        }
    }
}
