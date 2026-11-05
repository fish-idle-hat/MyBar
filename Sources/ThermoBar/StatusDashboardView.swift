import AppKit

/// A compact racing HUD with a fan tachometer, chip temperature, and CPU load.
final class StatusDashboardView: NSView {
    private var cpuUsage: Double?
    private var gpuUsage: Double?
    private var memoryUsage: Double?
    private var memoryPressure: MemoryPressureLevel = .normal
    private var pressureSamples = 0
    private var pendingPressure: MemoryPressureLevel = .normal
    private var lastPriorityLabel = "GPU"

    func setMemoryPressure(_ pressure: MemoryPressureLevel) {
        if pendingPressure == pressure { pressureSamples += 1 }
        else { pendingPressure = pressure; pressureSamples = 1 }
        if pressureSamples >= 3 { memoryPressure = pressure }
    }
    private var temperature: Double?
    private var batteryTemperature: Double?
    private var wifiLatencyMilliseconds: Double?
    private var memoryLeakAssessment: MemoryLeakAssessment?
    private var averageRPM: Double?
    private var fansConfirmedStopped = false
    private var readiness = CompassMenuReadiness()
    private var systemBaselineRPM: Double?
    private var isFanOverrideActive = false
    private var hasError = false
    private var chaseAnimationTimer: Timer?
    private var chaseAnimationFrame: Int?
    private var chaseReason: ChaseReason?
    private var hasExtractionFault = false
    private var batteryAlertTimer: Timer?
    private var isBatteryOverheated = false
    private var isBatteryAlertVisible = false
    private var latencyAlertTimer: Timer?
    private var isHighLatency = false
    private var isLatencyAlertVisible = false
    private var memoryLeakAlertTimer: Timer?
    private var isMemoryLeakSuspected = false
    private var isMemoryLeakAlertVisible = false
    private var lightAnimationTimer: Timer?
    private var lightAnimationReason: LightAnimationReason?
    private var lastSignificantChangeAnimationAt: Date?
    private let leftAlertLight = CAShapeLayer()
    private let rightAlertLight = CAShapeLayer()

    private static let batteryOverheatThreshold = 40.0
    private static let batteryOverheatClearThreshold = 38.0
    private static let highLatencyThreshold = 100.0
    private static let highLatencyClearThreshold = 80.0
    private static let fanRPMChangeThreshold = 1_000.0
    private static let chipTemperatureChangeThreshold = 10.0
    private static let batteryTemperatureChangeThreshold = 5.0
    private static let cpuUsageChangeThreshold = 0.30
    private static let memoryUsageChangeThreshold = 0.15

    private static let startupChasePositions = [0, 1, 2, 3, 4, 5, 6, 7, 6, 5, 4, 3, 2, 1, 0]
    private static let startupCenterBurstFrames: [Set<Int>] = [
        [], [], [3, 4], [3, 4], [2, 3, 4, 5], [2, 3, 4, 5],
        [1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5, 6],
        [0, 1, 2, 3, 4, 5, 6, 7], [0, 1, 2, 3, 4, 5, 6, 7],
        [0, 1, 2, 3, 4, 5, 6, 7],
        [1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 5, 6],
        [2, 3, 4, 5], [2, 3, 4, 5], [3, 4], [3, 4], [],
    ]
    private static let centerIgnitionFrames: [Set<Int>] = [
        [], [], [3, 4], [2, 3, 4, 5], [1, 2, 3, 4, 5, 6],
        [0, 1, 2, 3, 4, 5, 6, 7], [0, 1, 2, 3, 4, 5, 6, 7],
        [1, 2, 3, 4, 5, 6], [2, 3, 4, 5], [3, 4], [],
    ]

    private enum ChaseReason {
        case startup
        case extractionFault
        case fanStart
    }

    private enum LightAnimationReason: Equatable {
        case batteryOverheat
        case highLatency
        case memoryLeak
        case significantChange
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureAlertLights()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        configureAlertLights()
    }

    deinit {
        chaseAnimationTimer?.invalidate()
        batteryAlertTimer?.invalidate()
        latencyAlertTimer?.invalidate()
        memoryLeakAlertTimer?.invalidate()
        lightAnimationTimer?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // Keep the containing NSStatusBarButton clickable.
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let lightSize = CGSize(width: 2, height: 12)
        let y = (bounds.height - lightSize.height) / 2
        layoutAlertLight(leftAlertLight, frame: NSRect(x: 2.3, y: y, width: lightSize.width, height: lightSize.height))
        layoutAlertLight(
            rightAlertLight,
            frame: NSRect(x: bounds.width - 4.3, y: y, width: lightSize.width, height: lightSize.height)
        )
    }

    func update(
        cpuUsage: Double?,
        gpuUsage: Double?,
        memoryUsage: Double?,
        temperature: Double?,
        fanRPM: [Double?],
        batteryTemperature: Double?,
        wifiLatencyMilliseconds: Double?,
        memoryLeakAssessment: MemoryLeakAssessment?,
        stableAlerts: StableAlertState? = nil
    ) {
        let previousCPUUsage = self.cpuUsage
        let previousMemoryUsage = self.memoryUsage
        let previousTemperature = self.temperature
        let previousBatteryTemperature = self.batteryTemperature
        let previousRPM = averageRPM
        let updatedRPM = Self.averageFanRPM(fanRPM)
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsage = memoryUsage
        self.temperature = temperature
        self.batteryTemperature = batteryTemperature
        self.wifiLatencyMilliseconds = wifiLatencyMilliseconds
        self.memoryLeakAssessment = memoryLeakAssessment
        averageRPM = updatedRPM
        fansConfirmedStopped = Self.areFansConfirmedStopped(fanRPM)
        hasError = false
        if let stableAlerts {
            setBatteryAlert(active: stableAlerts.batteryOverheat)
            setLatencyAlert(active: stableAlerts.highLatency)
            setMemoryLeakAlert(active: stableAlerts.memoryLeak, assessment: memoryLeakAssessment)
        } else {
            updateBatteryAlert(for: batteryTemperature)
            updateLatencyAlert(for: wifiLatencyMilliseconds)
            updateMemoryLeakAlert(for: memoryLeakAssessment)
        }
        if Self.hasSignificantChange(
            previousFanRPM: previousRPM,
            currentFanRPM: updatedRPM,
            previousChipTemperature: previousTemperature,
            currentChipTemperature: temperature,
            previousBatteryTemperature: previousBatteryTemperature,
            currentBatteryTemperature: batteryTemperature,
            previousCPUUsage: previousCPUUsage,
            currentCPUUsage: cpuUsage,
            previousMemoryUsage: previousMemoryUsage,
            currentMemoryUsage: memoryUsage
        ), !isBatteryOverheated, !isHighLatency, !isMemoryLeakSuspected,
           lastSignificantChangeAnimationAt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
            lastSignificantChangeAnimationAt = Date()
            startLightAnimation(reason: .significantChange)
        }
        if Self.didFanStart(previousRPM: previousRPM, currentRPM: updatedRPM),
           !hasExtractionFault,
           chaseReason == nil {
            startChase(reason: .fanStart)
        }
        let priorityLabel = isBatteryOverheated ? "BAT"
            : isMemoryLeakSuspected || memoryPressure == .critical ? "MEM"
            : isHighLatency ? "MS" : memoryPressure == .warning ? "MEM" : "GPU"
        if priorityLabel != lastPriorityLabel {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.16
                layer?.add(fade, forKey: "priority")
            }
            lastPriorityLabel = priorityLabel
        }
        needsDisplay = true
    }

    func setFanControlPresentation(systemBaselineRPM: Double?, isOverrideActive: Bool) {
        self.systemBaselineRPM = systemBaselineRPM
        isFanOverrideActive = isOverrideActive
        needsDisplay = true
    }

    func setReadiness(_ readiness: CompassMenuReadiness) {
        self.readiness = readiness
        needsDisplay = true
    }

    struct PrimaryMetric: Equatable {
        let value: String
        let label: String
        let warning: Bool
        let high: Bool
    }

    func primaryMetric(at now: Date = Date()) -> PrimaryMetric {
        // Never hide a thermal warning or mistake a missing fan reading for zero RPM.
        if fansConfirmedStopped, !Self.isTemperatureWarning(temperature), !Self.isTemperatureHigh(temperature) {
            return PrimaryMetric(value: readiness.percentage(at: now).map { "\($0)%" } ?? "—%",
                                 label: "RDY", warning: false, high: false)
        }
        return PrimaryMetric(value: temperature.map { "\(Int($0.rounded()))°" } ?? "—°", label: "TEMP",
                             warning: Self.isTemperatureWarning(temperature), high: Self.isTemperatureHigh(temperature))
    }

    func primaryMetricExplanation(at now: Date = Date()) -> String {
        let metric = primaryMetric(at: now)
        if metric.label == "RDY" {
            return "\(readiness.explanation(at: now)) Blue bar: chip temperature, 40–80°C."
        }
        return "Chip temperature \(metric.value) Celsius. \(fansConfirmedStopped ? "Thermal warning takes priority over readiness. Blue bar: 40–80°C." : "Bar: average fan RPM, 0–8000.")"
    }

    static func areFansConfirmedStopped(_ readings: [Double?]) -> Bool {
        !readings.isEmpty && readings.allSatisfy { $0.map { $0.isFinite && $0 == 0 } ?? false }
    }

    func showLoading() {
        cpuUsage = nil
        gpuUsage = nil
        memoryUsage = nil
        temperature = nil
        batteryTemperature = nil
        wifiLatencyMilliseconds = nil
        memoryLeakAssessment = nil
        averageRPM = nil
        fansConfirmedStopped = false
        hasError = false
        stopBatteryAlert()
        stopLatencyAlert()
        stopMemoryLeakAlert()
        stopLightAnimation()
        needsDisplay = true
    }

    func showError() {
        hasError = true
        stopLightAnimation()
        setExtractionFault(true)
        needsDisplay = true
    }

    func startRPMStartupAnimation() {
        startChase(reason: .startup)
    }

    func setExtractionFault(_ hasFault: Bool) {
        hasExtractionFault = hasFault
        if hasFault {
            if chaseReason == nil || chaseReason == .fanStart {
                startChase(reason: .extractionFault)
            }
        } else if chaseReason == .extractionFault {
            stopChase()
        }
    }

    static func isCoreDataIncomplete(
        temperature: Double?,
        cpuUsage: Double?,
        gpuUsage: Double?,
        memoryUsage: Double?,
        fanRPM: [Double?]
    ) -> Bool {
        temperature == nil
            || cpuUsage == nil
            || gpuUsage == nil
            || memoryUsage == nil
            || fanRPM.isEmpty
            || fanRPM.contains { $0 == nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPanel()
        drawSegmentTachometer()

        if hasError {
            drawCentered(
                "SENSOR ERROR",
                in: NSRect(x: 3, y: 1, width: bounds.width - 6, height: 9),
                fontSize: 6.2,
                weight: .bold,
                color: .systemRed
            )
            return
        }

        let metricY: CGFloat = 1.1
        let metricHeight: CGFloat = 8.5
        let primary = primaryMetric()
        drawInlineMetric(
            value: primary.value,
            label: primary.label,
            isWarning: primary.warning,
            isHigh: primary.high,
            in: NSRect(x: 3, y: metricY, width: 33, height: metricHeight)
        )
        drawInlineMetric(
            value: cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—%",
            label: "CPU",
            isWarning: Self.isCPULoadWarning(cpuUsage),
            isHigh: Self.isLoadHigh(cpuUsage),
            in: NSRect(x: 37, y: metricY, width: 32, height: metricHeight)
        )
        let priority: (String, String, Bool, Bool)
        if isBatteryOverheated {
            priority = (batteryTemperature.map { "\(Int($0.rounded()))°" } ?? "—", "BAT", false, true)
        } else if isMemoryLeakSuspected || memoryPressure == .critical {
            priority = (memoryUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "MEM", false, true)
        } else if isHighLatency {
            priority = (wifiLatencyMilliseconds.map { "\(min(999, Int($0.rounded())))" } ?? "—", "MS", true, false)
        } else if memoryPressure == .warning {
            priority = (memoryUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", "MEM", true, false)
        } else {
            priority = (gpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "—%", "GPU",
                        Self.isCPULoadWarning(gpuUsage), Self.isLoadHigh(gpuUsage))
        }
        drawInlineMetric(
            value: priority.0,
            label: priority.1,
            isWarning: priority.2,
            isHigh: priority.3,
            in: NSRect(x: 70, y: metricY, width: 35, height: metricHeight)
        )
    }

    static func averageFanRPM(_ readings: [Double?]) -> Double? {
        let available = readings.compactMap { $0 }
        guard !available.isEmpty else { return nil }
        return available.reduce(0, +) / Double(available.count)
    }

    /// The 0–8 scale represents 0–8000 RPM.
    static func tachometerProgress(for rpm: Double?) -> CGFloat {
        guard let rpm else { return 0 }
        return CGFloat(min(1, max(0, rpm / 8_000)))
    }

    static func activeSegmentCount(for rpm: Double?) -> Int {
        guard let rpm, rpm > 0 else { return 0 }
        return min(8, Int(ceil(rpm / 1_000)))
    }

    struct TachometerFill: Equatable {
        let system: CGFloat
        let boost: CGFloat
    }

    /// Returns the exact fill of each 1,000-RPM capsule instead of rounding the
    /// live reading up to a full capsule.
    static func tachometerFills(
        currentRPM: Double?,
        systemBaselineRPM: Double?,
        isOverrideActive: Bool
    ) -> [TachometerFill] {
        let current = min(8_000, max(0, currentRPM ?? 0))
        let baseline = isOverrideActive
            ? min(current, min(8_000, max(0, systemBaselineRPM ?? current)))
            : current

        return (0..<8).map { index in
            let lowerBound = Double(index) * 1_000
            let currentFill = min(1, max(0, (current - lowerBound) / 1_000))
            let systemFill = min(currentFill, max(0, (baseline - lowerBound) / 1_000))
            return TachometerFill(
                system: CGFloat(systemFill),
                boost: CGFloat(currentFill - systemFill)
            )
        }
    }

    static func shouldShowThermalHeadroom(for rpm: Double?) -> Bool {
        rpm.map { $0.isFinite && $0 == 0 } ?? false
    }

    /// Maps the useful 40–80°C range onto the eight-segment bar. Keep one
    /// blue segment visible while idle so thermal mode is always recognizable.
    static func thermalHeadroomSegmentCount(for temperature: Double?) -> Int {
        guard let temperature, temperature.isFinite else { return 0 }
        let progress = min(1, max(0, (temperature - 40) / 40))
        return max(1, min(8, Int(ceil(progress * 8))))
    }

    enum TachometerSegment: Equatable {
        case inactive
        case system
        case boost
    }

    static func tachometerSegments(
        currentRPM: Double?,
        systemBaselineRPM: Double?,
        isOverrideActive: Bool
    ) -> [TachometerSegment] {
        let currentCount = activeSegmentCount(for: currentRPM)
        guard isOverrideActive, systemBaselineRPM != nil else {
            return (0..<8).map { $0 < currentCount ? .system : .inactive }
        }
        let systemCount = min(currentCount, activeSegmentCount(for: systemBaselineRPM))
        return (0..<8).map { index in
            if index < systemCount { return .system }
            if index < currentCount { return .boost }
            return .inactive
        }
    }

    static func isTemperatureHigh(_ value: Double?) -> Bool {
        value.map { $0 >= 90 } ?? false
    }

    static func isTemperatureWarning(_ value: Double?) -> Bool {
        value.map { $0 >= 80 && $0 < 90 } ?? false
    }

    static func isLoadHigh(_ value: Double?) -> Bool {
        value.map { $0 >= 0.90 } ?? false
    }

    static func isCPULoadWarning(_ value: Double?) -> Bool {
        value.map { $0 >= 0.85 && $0 < 0.90 } ?? false
    }

    static func isBatteryOverheat(_ value: Double?) -> Bool {
        value.map { $0 >= batteryOverheatThreshold } ?? false
    }

    static func shouldKeepBatteryOverheat(_ value: Double?) -> Bool {
        value.map { $0 >= batteryOverheatClearThreshold } ?? false
    }

    static func isLatencyHigh(_ value: Double?) -> Bool {
        value.map { $0 >= highLatencyThreshold } ?? false
    }

    static func shouldKeepHighLatency(_ value: Double?) -> Bool {
        value.map { $0 >= highLatencyClearThreshold } ?? false
    }

    static func hasSignificantChange(
        previousFanRPM: Double?,
        currentFanRPM: Double?,
        previousChipTemperature: Double?,
        currentChipTemperature: Double?,
        previousBatteryTemperature: Double?,
        currentBatteryTemperature: Double?,
        previousCPUUsage: Double?,
        currentCPUUsage: Double?,
        previousMemoryUsage: Double?,
        currentMemoryUsage: Double?
    ) -> Bool {
        exceedsThreshold(previousFanRPM, currentFanRPM, threshold: fanRPMChangeThreshold)
            || exceedsThreshold(previousChipTemperature, currentChipTemperature, threshold: chipTemperatureChangeThreshold)
            || exceedsThreshold(previousBatteryTemperature, currentBatteryTemperature, threshold: batteryTemperatureChangeThreshold)
            || exceedsThreshold(previousCPUUsage, currentCPUUsage, threshold: cpuUsageChangeThreshold)
            || exceedsThreshold(previousMemoryUsage, currentMemoryUsage, threshold: memoryUsageChangeThreshold)
    }

    private static func exceedsThreshold(_ previous: Double?, _ current: Double?, threshold: Double) -> Bool {
        guard let previous, let current else { return false }
        return abs(current - previous) >= threshold
    }

    static func startupChaseSegments(forFrame frame: Int) -> Set<Int> {
        let pathIndex = frame - 2
        guard startupChasePositions.indices.contains(pathIndex) else { return [] }

        let position = startupChasePositions[pathIndex]
        let neighbor = min(7, position + 1)
        return [position, neighbor]
    }

    static func startupCenterBurstSegments(forFrame frame: Int) -> Set<Int> {
        guard startupCenterBurstFrames.indices.contains(frame) else { return [] }
        return startupCenterBurstFrames[frame]
    }

    static func centerIgnitionSegments(forFrame frame: Int) -> Set<Int> {
        guard centerIgnitionFrames.indices.contains(frame) else { return [] }
        return centerIgnitionFrames[frame]
    }

    static func didFanStart(previousRPM: Double?, currentRPM: Double?) -> Bool {
        guard let previousRPM, let currentRPM else { return false }
        return previousRPM <= 0 && currentRPM > 0
    }

    private func drawPanel() {
        let panel = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 6,
            yRadius: 6
        )
        panelColor.setFill()
        panel.fill()
        foregroundColor.withAlphaComponent(0.16).setStroke()
        panel.lineWidth = 0.5
        panel.stroke()
    }

    private func configureAlertLights() {
        for light in [leftAlertLight, rightAlertLight] {
            light.fillColor = NSColor.systemRed.cgColor
            light.shadowColor = NSColor.systemRed.cgColor
            light.shadowOpacity = 0.55
            light.shadowRadius = 1.3
            light.shadowOffset = .zero
            light.opacity = 0
            layer?.addSublayer(light)
        }
    }

    private func layoutAlertLight(_ light: CAShapeLayer, frame: NSRect) {
        light.frame = frame
        light.path = CGPath(roundedRect: light.bounds, cornerWidth: 1, cornerHeight: 1, transform: nil)
    }

    private func drawSegmentTachometer() {
        let segmentCount = 8
        let horizontalInset: CGFloat = 5
        let gap: CGFloat = 2
        let height: CGFloat = 3
        let availableWidth = bounds.width - horizontalInset * 2 - gap * CGFloat(segmentCount - 1)
        let segmentWidth = availableWidth / CGFloat(segmentCount)
        let segmentFills = Self.tachometerFills(
            currentRPM: averageRPM,
            systemBaselineRPM: systemBaselineRPM,
            isOverrideActive: isFanOverrideActive
        )
        let isThermalHeadroom = fansConfirmedStopped
        let thermalSegmentCount = Self.thermalHeadroomSegmentCount(for: temperature)
        let chaseSegments = chaseAnimationFrame.map { frame in
            switch chaseReason {
            case .startup: Self.startupCenterBurstSegments(forFrame: frame)
            case .fanStart: Self.centerIgnitionSegments(forFrame: frame)
            case .extractionFault, .none: Self.startupChaseSegments(forFrame: frame)
            }
        }

        for index in 0..<segmentCount {
            let rect = NSRect(
                x: horizontalInset + CGFloat(index) * (segmentWidth + gap),
                y: bounds.maxY - 5.5,
                width: segmentWidth,
                height: height
            )
            let segment = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
            let color: NSColor
            if let chaseSegments {
                if chaseSegments.contains(index) {
                    color = chaseReason == .startup
                        ? (index.isMultiple(of: 2) ? .systemRed : .systemBlue)
                        : .systemRed
                } else {
                    color = inactiveSegmentColor
                }
            } else if isThermalHeadroom {
                color = index < thermalSegmentCount
                    ? .systemBlue
                    : inactiveSegmentColor
            } else {
                color = inactiveSegmentColor
            }
            color.setFill()
            segment.fill()
            inactiveSegmentBorderColor.setStroke()
            segment.lineWidth = 0.4
            segment.stroke()

            guard chaseSegments == nil, !isThermalHeadroom else { continue }
            let fill = segmentFills[index]
            guard fill.system > 0 || fill.boost > 0 else { continue }
            NSGraphicsContext.saveGraphicsState()
            segment.addClip()
            if fill.system > 0 {
                NSColor.systemRed.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: rect.width * fill.system, height: rect.height).fill()
            }
            if fill.boost > 0 {
                NSColor.systemOrange.setFill()
                NSRect(
                    x: rect.minX + rect.width * fill.system,
                    y: rect.minY,
                    width: rect.width * fill.boost,
                    height: rect.height
                ).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        drawCentered(
            isThermalHeadroom ? "40°" : "0",
            in: NSRect(x: 3.5, y: 9.5, width: isThermalHeadroom ? 12 : 7, height: 5.5),
            fontSize: isThermalHeadroom ? 4.0 : 4.4,
            weight: .medium,
            color: isThermalHeadroom ? .systemBlue : foregroundColor.withAlphaComponent(0.82)
        )
        drawCentered(
            isThermalHeadroom ? "80°" : "8K",
            in: NSRect(x: bounds.width - (isThermalHeadroom ? 15 : 13), y: 9.5, width: isThermalHeadroom ? 12 : 10, height: 5.5),
            fontSize: isThermalHeadroom ? 4.0 : 4.4,
            weight: .medium,
            color: isThermalHeadroom ? .systemBlue : foregroundColor.withAlphaComponent(0.82)
        )
    }

    private func drawInlineMetric(
        value: String,
        label: String,
        isWarning: Bool,
        isHigh: Bool,
        in rect: NSRect
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let animationOpacity: CGFloat = chaseAnimationFrame == nil ? 1 : 0.34
        let metricColor = isHigh ? NSColor.systemRed : isWarning ? NSColor.systemOrange : foregroundColor
        let isAlert = isWarning || isHigh

        let text = NSMutableAttributedString(
            string: value,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.2, weight: .bold),
                .foregroundColor: metricColor.withAlphaComponent(animationOpacity),
            ]
        )
        text.append(NSAttributedString(
            string: " \(label)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 3.5, weight: .medium),
                .foregroundColor: metricColor.withAlphaComponent((isAlert ? 0.90 : 0.68) * animationOpacity),
            ]
        ))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))

        let size = text.size()
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height))
    }

    private func drawBatteryAlert() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSMutableAttributedString(
            string: "BATTERY HOT · ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 5.4, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        text.append(NSAttributedString(
            string: batteryTemperature.map { "\(Int($0.rounded()))°" } ?? "—°",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.2, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        ))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let rect = NSRect(x: 3, y: 1.1, width: bounds.width - 6, height: 8.5)
        let size = text.size()
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height))
    }

    private func drawLatencyAlert() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSMutableAttributedString(
            string: "HIGH LATENCY · ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 5.4, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        text.append(NSAttributedString(
            string: wifiLatencyMilliseconds.map { "\(Int($0.rounded())) ms" } ?? "— ms",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 7.2, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        ))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let rect = NSRect(x: 3, y: 1.1, width: bounds.width - 6, height: 8.5)
        let size = text.size()
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height))
    }

    private func drawMemoryLeakAlert() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSMutableAttributedString(
            string: "MEMORY LEAK? · ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 5.2, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        text.append(NSAttributedString(
            string: memoryLeakAssessment.map { String(format: "+%.1f GB", Double($0.growthBytes) / 1_000_000_000) } ?? "+— GB",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 6.8, weight: .bold),
                .foregroundColor: NSColor.systemRed,
            ]
        ))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let rect = NSRect(x: 3, y: 1.1, width: bounds.width - 6, height: 8.5)
        let size = text.size()
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height))
    }

    private func updateBatteryAlert(for temperature: Double?) {
        let shouldBeOverheated = isBatteryOverheated
            ? Self.shouldKeepBatteryOverheat(temperature)
            : Self.isBatteryOverheat(temperature)

        guard shouldBeOverheated != isBatteryOverheated else { return }
        isBatteryOverheated = shouldBeOverheated

        if shouldBeOverheated {
            startBatteryAlert()
        } else {
            stopBatteryAlert()
        }
    }

    private func setBatteryAlert(active: Bool) {
        guard active != isBatteryOverheated else { return }
        isBatteryOverheated = active
        active ? startBatteryAlert() : stopBatteryAlert()
    }

    private func startBatteryAlert() {
        batteryAlertTimer?.invalidate()
        isBatteryAlertVisible = true
        startLightAnimation(reason: .batteryOverheat)
        needsDisplay = true

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.isBatteryAlertVisible.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryAlertTimer = timer
    }

    private func stopBatteryAlert() {
        batteryAlertTimer?.invalidate()
        batteryAlertTimer = nil
        isBatteryOverheated = false
        isBatteryAlertVisible = false
        if lightAnimationReason == .batteryOverheat {
            stopLightAnimation()
        }
        needsDisplay = true
    }

    private func updateLatencyAlert(for milliseconds: Double?) {
        let shouldBeHigh = isHighLatency
            ? Self.shouldKeepHighLatency(milliseconds)
            : Self.isLatencyHigh(milliseconds)
        guard shouldBeHigh != isHighLatency else { return }
        isHighLatency = shouldBeHigh

        if shouldBeHigh {
            startLatencyAlert()
        } else {
            stopLatencyAlert()
        }
    }

    private func setLatencyAlert(active: Bool) {
        guard active != isHighLatency else { return }
        isHighLatency = active
        active ? startLatencyAlert() : stopLatencyAlert()
    }

    private func startLatencyAlert() {
        latencyAlertTimer?.invalidate()
        isLatencyAlertVisible = true
        if !isBatteryOverheated {
            startLightAnimation(reason: .highLatency)
        }
        needsDisplay = true

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.isLatencyAlertVisible.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        latencyAlertTimer = timer
    }

    private func stopLatencyAlert() {
        latencyAlertTimer?.invalidate()
        latencyAlertTimer = nil
        isHighLatency = false
        isLatencyAlertVisible = false
        if lightAnimationReason == .highLatency {
            stopLightAnimation()
        }
        needsDisplay = true
    }

    private func updateMemoryLeakAlert(for assessment: MemoryLeakAssessment?) {
        let shouldWarn = assessment != nil
        memoryLeakAssessment = assessment
        guard shouldWarn != isMemoryLeakSuspected else { return }
        isMemoryLeakSuspected = shouldWarn

        if shouldWarn {
            startMemoryLeakAlert()
        } else {
            stopMemoryLeakAlert()
        }
    }

    private func setMemoryLeakAlert(active: Bool, assessment: MemoryLeakAssessment?) {
        memoryLeakAssessment = assessment
        guard active != isMemoryLeakSuspected else { return }
        isMemoryLeakSuspected = active
        active ? startMemoryLeakAlert() : stopMemoryLeakAlert()
    }

    private func startMemoryLeakAlert() {
        memoryLeakAlertTimer?.invalidate()
        isMemoryLeakAlertVisible = true
        if !isBatteryOverheated, !isHighLatency {
            startLightAnimation(reason: .memoryLeak)
        }
        needsDisplay = true

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.isMemoryLeakAlertVisible.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        memoryLeakAlertTimer = timer
    }

    private func stopMemoryLeakAlert() {
        memoryLeakAlertTimer?.invalidate()
        memoryLeakAlertTimer = nil
        isMemoryLeakSuspected = false
        isMemoryLeakAlertVisible = false
        if lightAnimationReason == .memoryLeak {
            stopLightAnimation()
        }
        needsDisplay = true
    }

    private func startLightAnimation(reason: LightAnimationReason) {
        lightAnimationTimer?.invalidate()
        lightAnimationTimer = nil
        lightAnimationReason = reason
        for light in [leftAlertLight, rightAlertLight] { light.removeAnimation(forKey: "pulse") }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for light in [leftAlertLight, rightAlertLight] { light.opacity = 1 }
            if reason == .significantChange || reason == .highLatency || reason == .memoryLeak {
                let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
                    self?.stopLightAnimation()
                }
                RunLoop.main.add(timer, forMode: .common)
                lightAnimationTimer = timer
            }
            return
        }

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if reason == .batteryOverheat {
            animation.values = [0.10, 1.0, 0.10]
            animation.keyTimes = [0, 0.5, 1]
            animation.duration = 1.2
            animation.repeatCount = .infinity
        } else {
            animation.values = [0.0, 1.0, 0.0, 0.0, 1.0, 0.0]
            animation.keyTimes = [0, 0.18, 0.38, 0.55, 0.75, 1]
            animation.duration = 1.3
            let timer = Timer(timeInterval: 1.32, repeats: false) { [weak self] _ in
                self?.stopLightAnimation()
            }
            timer.tolerance = 0.04
            RunLoop.main.add(timer, forMode: .common)
            lightAnimationTimer = timer
        }
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for light in [leftAlertLight, rightAlertLight] {
            light.opacity = 0
            light.add(animation, forKey: "pulse")
        }
    }

    private func stopLightAnimation() {
        lightAnimationTimer?.invalidate()
        lightAnimationTimer = nil
        lightAnimationReason = nil
        for light in [leftAlertLight, rightAlertLight] {
            light.removeAnimation(forKey: "pulse")
            light.opacity = 0
        }
    }

    private func startChase(reason: ChaseReason) {
        chaseAnimationTimer?.invalidate()
        chaseReason = reason

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            chaseAnimationFrame = nil
            chaseReason = nil
            needsDisplay = true
            return
        }

        chaseAnimationFrame = 0
        needsDisplay = true

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self, let frame = self.chaseAnimationFrame, let reason = self.chaseReason else {
                timer.invalidate()
                return
            }

            let nextFrame = frame + 1
            switch reason {
            case .startup where nextFrame >= Self.startupCenterBurstFrames.count:
                if self.hasExtractionFault {
                    self.chaseReason = .extractionFault
                    self.chaseAnimationFrame = 0
                } else {
                    self.stopChase()
                }
            case .extractionFault where !self.hasExtractionFault:
                self.stopChase()
            case .extractionFault where nextFrame >= 30:
                self.chaseAnimationFrame = 0
            case .fanStart where nextFrame >= Self.centerIgnitionFrames.count:
                self.stopChase()
            default:
                self.chaseAnimationFrame = nextFrame
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        chaseAnimationTimer = timer
    }

    private func stopChase() {
        chaseAnimationTimer?.invalidate()
        chaseAnimationTimer = nil
        chaseAnimationFrame = nil
        chaseReason = nil
        needsDisplay = true
    }

    private var usesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var panelColor: NSColor {
        usesDarkAppearance ? .black : .white
    }

    private var foregroundColor: NSColor {
        usesDarkAppearance ? .white : .black
    }

    private var inactiveSegmentColor: NSColor {
        foregroundColor.withAlphaComponent(usesDarkAppearance ? 0.28 : 0.18)
    }

    private var inactiveSegmentBorderColor: NSColor {
        foregroundColor.withAlphaComponent(usesDarkAppearance ? 0.42 : 0.24)
    }

    private func drawCentered(
        _ text: String,
        in rect: NSRect,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height))
    }
}
