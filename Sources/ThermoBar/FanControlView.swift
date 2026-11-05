import AppKit
import FanControlProtocol
import QuartzCore

final class FanControlView: NSView {
    static let preferredSize = NSSize(width: 360, height: 188)
    private static let temperatureOriginY: CGFloat = 196
    private static let temperatureHeaderHeight: CGFloat = 34
    private static let temperatureInsightHeight: CGFloat = 102
    private static let temperatureGroupHeight: CGFloat = 20
    private static let temperatureRowHeight: CGFloat = 18

    struct TemperatureDisplaySensor: Equatable {
        let group: SensorGroup
        let groupTitle: String
        let name: String
        let key: String
        let celsius: Double
        let health: SensorHealth
    }

    struct TemperatureInsight: Equatable {
        enum Severity: Int, Equatable {
            case warning
            case critical
        }

        let sensor: TemperatureDisplaySensor
        let severity: Severity
        let deviationFromGroupMedian: Double
        let assessment: String
        let location: String
        let reason: String
        let solution: String
        let score: Double
    }

    var onModeChange: ((FanControlMode) -> Void)?
    var onProfileChange: ((FanResponseProfile) -> Void)?
    var onSmartRulesChange: ((Bool) -> Void)?
    var onManualTargetsChange: (([FanTarget]) -> Void)?
    var onEnableHelper: (() -> Void)?
    var onRestoreSystem: (() -> Void)?
    var onContentHeightChange: (() -> Void)?
    private(set) var minimumContentHeight = FanControlView.preferredSize.height

    private let fanIcon = SpinningFanView()
    private let titleLabel = NSTextField(labelWithString: "Fans")
    private let stopButton = NSButton()
    private let modeControl = NSSegmentedControl(labels: ["System", "Manual", "Auto Boost"], trackingMode: .selectOne, target: nil, action: nil)
    private let linkButton = NSButton()
    private let settingsButton = NSButton()
    private let leftRow = FanRPMRowView(side: "Left Side", fanIndex: 0)
    private let rightRow = FanRPMRowView(side: "Right Side", fanIndex: 1)
    private let helperButton = NSButton(title: "Enable Helper…", target: nil, action: nil)
    private let helperProgress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Monitoring remains independent")

    private var currentProfile: FanResponseProfile = .balanced
    private var smartRulesEnabled = false
    private var smartRulesReason = "Disabled"
    private var capabilities: [FanCapability] = []
    private var manualDraft: [Int: Double] = [:]
    private var fansLinked = true
    private var showsHelperAuthorization = true
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverRect = NSRect.zero
    private var hoverTargetRect = NSRect.zero
    private var hoverOpacity: CGFloat = 0
    private var hoverTargetOpacity: CGFloat = 0
    private var hoverAnimationTimer: Timer?
    private var temperatureSensors: [TemperatureDisplaySensor] = []
    private var temperatureInsights: [TemperatureInsight] = []
    private var temperatureSensorCount = 0

    override var isFlipped: Bool { true }
    override var isHidden: Bool {
        didSet { fanIcon.setAnimationEnabled(!isHidden) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [fanIcon, titleLabel, stopButton, modeControl, linkButton, settingsButton,
         leftRow, rightRow, helperButton, helperProgress, statusLabel].forEach(addSubview)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: 9.5, weight: .medium)
        modeControl.selectedSegment = FanControlMode.system.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        configureIconButton(stopButton, symbol: "stop.fill", accessibilityLabel: "Return to System control")
        stopButton.contentTintColor = .systemRed
        stopButton.target = self
        stopButton.action = #selector(restoreSystem)

        configureIconButton(linkButton, symbol: "link", accessibilityLabel: "Keep fan targets synchronized")
        linkButton.target = self
        linkButton.action = #selector(toggleLink)

        configureIconButton(settingsButton, symbol: "gearshape", accessibilityLabel: "Auto Boost profile")
        settingsButton.target = self
        settingsButton.action = #selector(showProfileMenu)

        helperButton.bezelStyle = .rounded
        helperButton.controlSize = .small
        helperButton.font = .systemFont(ofSize: 10.5, weight: .medium)
        helperButton.target = self
        helperButton.action = #selector(enableHelper)

        helperProgress.style = .spinning
        helperProgress.controlSize = .small
        helperProgress.isDisplayedWhenStopped = false

        statusLabel.font = .systemFont(ofSize: 9.5)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        leftRow.onPreview = { [weak self] index, rpm in self?.previewManualTarget(index: index, rpm: rpm) }
        rightRow.onPreview = { [weak self] index, rpm in self?.previewManualTarget(index: index, rpm: rpm) }
        leftRow.onCommit = { [weak self] index, rpm in self?.commitManualTarget(index: index, rpm: rpm) }
        rightRow.onCommit = { [weak self] index, rpm in self?.commitManualTarget(index: index, rpm: rpm) }

        updateLinkAppearance()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dual fan controller")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        hoverAnimationTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        fanIcon.frame = NSRect(x: 21, y: 11, width: 24, height: 24)
        titleLabel.frame = NSRect(x: 46, y: 13, width: 42, height: 20)
        stopButton.frame = NSRect(x: 89, y: 12, width: 23, height: 23)
        modeControl.frame = NSRect(x: 116, y: 10, width: 171, height: 27)
        modeControl.setWidth(55, forSegment: 0)
        modeControl.setWidth(55, forSegment: 1)
        modeControl.setWidth(61, forSegment: 2)
        linkButton.frame = NSRect(x: 293, y: 12, width: 25, height: 23)
        settingsButton.frame = NSRect(x: 325, y: 12, width: 22, height: 23)

        leftRow.frame = NSRect(x: 16, y: 48, width: bounds.width - 32, height: 51)
        rightRow.frame = NSRect(x: 16, y: 103, width: bounds.width - 32, height: 51)

        helperButton.frame = NSRect(x: 16, y: 159, width: 132, height: 24)
        helperProgress.frame = NSRect(x: 128, y: 164, width: 14, height: 14)
        statusLabel.frame = showsHelperAuthorization
            ? NSRect(x: 156, y: 158, width: 188, height: 27)
            : NSRect(x: 18, y: 163, width: 324, height: 16)
        statusLabel.alignment = showsHelperAuthorization ? .natural : .center
        statusLabel.maximumNumberOfLines = showsHelperAuthorization ? 2 : 1
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let panel = NSBezierPath(roundedRect: NSRect(x: 10, y: 4, width: bounds.width - 20, height: 180), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.withAlphaComponent(0.50).setFill()
        panel.fill()
        NSColor.separatorColor.withAlphaComponent(0.60).setStroke()
        panel.lineWidth = 0.7
        panel.stroke()

        drawSeparator(y: 43)
        drawSeparator(y: 101, inset: 16)
        drawSeparator(y: 156, inset: 16)

        if hoverOpacity > 0.01, !hoverRect.isEmpty {
            let width = min(26, hoverRect.width * 0.42)
            let rect = NSRect(x: hoverRect.midX - width / 2, y: hoverRect.maxY + 1, width: width, height: 1.4)
            NSColor.controlAccentColor.withAlphaComponent(0.55 * hoverOpacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.7, yRadius: 0.7).fill()
        }

        drawTemperatures(in: dirtyRect)
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        hoverTargetOpacity = 0
        startHoverAnimationIfNeeded()
    }

    func update(_ state: FanControlViewState) {
        capabilities = state.capabilities.sorted { $0.index < $1.index }
        currentProfile = state.profile
        updateSmartRules(enabled: state.smartRulesEnabled, reason: state.smartRulesReason)
        modeControl.selectedSegment = state.selectedMode.rawValue
        modeControl.setEnabled(true, forSegment: FanControlMode.system.rawValue)
        modeControl.setEnabled(state.helperReady, forSegment: FanControlMode.manual.rawValue)
        modeControl.setEnabled(state.helperReady, forSegment: FanControlMode.smart.rawValue)

        if state.selectedMode == .manual, !leftRow.slider.isInteracting, !rightRow.slider.isInteracting {
            manualDraft = Dictionary(uniqueKeysWithValues: state.manualTargets.map { ($0.index, $0.rpm) })
        }

        let activeTargets = Dictionary(uniqueKeysWithValues: state.targets.map { ($0.index, $0.rpm) })
        let storedManualTargets = Dictionary(uniqueKeysWithValues: state.manualTargets.map { ($0.index, $0.rpm) })
        let manualTargets = manualDraft.isEmpty ? storedManualTargets : manualDraft
        let displayedTargets = state.selectedMode == .manual ? manualTargets : activeTargets
        let showsTarget = state.selectedMode != .system
        let editable = state.selectedMode == .manual
            && state.helperReady
            && state.applyFeedback != .working

        updateRow(leftRow, index: 0, state: state, target: showsTarget ? displayedTargets[0] : nil, editable: editable)
        updateRow(rightRow, index: 1, state: state, target: showsTarget ? displayedTargets[1] : nil, editable: editable)

        fanIcon.update(rpm: StatusDashboardView.averageFanRPM(state.actualRPM))
        stopButton.isHidden = state.activeMode == .system
        linkButton.isHidden = state.selectedMode != .manual
        linkButton.isEnabled = editable
        settingsButton.contentTintColor = state.selectedMode == .smart ? .controlAccentColor : .secondaryLabelColor
        settingsButton.toolTip = "Auto Boost profile: \(state.profile.displayName)"

        updateHelperFeedback(state)
        statusLabel.stringValue = state.status
        if state.applyFeedback == .failed {
            statusLabel.textColor = .systemOrange
        } else if state.applyFeedback == .confirmed {
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }

        setAccessibilityValue("\(leftRow.accessibilitySummary), \(rightRow.accessibilitySummary). \(state.status)")
        needsLayout = true
        needsDisplay = true
    }

    func updateTemperatures(
        _ readings: [TemperatureReading],
        cpuUsage: Double? = nil,
        gpuUsage: Double? = nil,
        topApps: [TopAppMetrics] = [],
        thermalState: ProcessInfo.ThermalState = .nominal
    ) {
        let sensors = Self.temperatureDisplaySensors(readings)
        temperatureInsights = Self.detectTemperatureInsights(
            sensors,
            cpuUsage: cpuUsage,
            gpuUsage: gpuUsage,
            topApps: topApps,
            thermalState: thermalState
        )
        temperatureSensorCount = sensors.count
        let pinnedKey = temperatureInsights.first?.sensor.key
        temperatureSensors = sensors.filter { $0.key != pinnedKey }
        let groups = Set(temperatureSensors.map(\.group)).count
        let contentHeight = Self.temperatureOriginY
            + Self.temperatureHeaderHeight
            + (temperatureInsights.isEmpty ? 0 : Self.temperatureInsightHeight)
            + CGFloat(groups) * Self.temperatureGroupHeight
            + CGFloat(temperatureSensors.count) * Self.temperatureRowHeight
            + 12
        minimumContentHeight = max(Self.preferredSize.height, contentHeight)
        if frame.height < minimumContentHeight {
            frame.size.height = minimumContentHeight
        }
        onContentHeightChange?()
        needsDisplay = true
    }

    func updateSmartRules(enabled: Bool, reason: String) {
        smartRulesEnabled = enabled
        smartRulesReason = reason
        settingsButton.toolTip = enabled
            ? "Auto Boost profile · Smart Rules: \(reason)"
            : "Auto Boost profile"
    }

    static func temperatureDisplaySensors(_ readings: [TemperatureReading]) -> [TemperatureDisplaySensor] {
        let groupOrder: [SensorGroup] = [.cpu, .gpu, .hotspot, .other]
        let titles: [SensorGroup: String] = [
            .cpu: "CPU",
            .gpu: "GPU",
            .hotspot: "HOTSPOTS",
            .other: "OTHER SENSORS",
        ]
        let names: [SensorGroup: String] = [
            .cpu: "CPU Sensor",
            .gpu: "GPU Region",
            .hotspot: "Hotspot",
            .other: "System Sensor",
        ]

        return groupOrder.flatMap { group in
            readings
                .filter { $0.group == group && $0.celsius.isFinite }
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .enumerated()
                .map { offset, reading in
                    TemperatureDisplaySensor(
                        group: group,
                        groupTitle: titles[group] ?? "SENSORS",
                        name: "\(names[group] ?? "Sensor") \(offset + 1)",
                        key: reading.key,
                        celsius: reading.celsius,
                        health: reading.health()
                    )
                }
        }
    }

    static func detectTemperatureInsights(
        _ sensors: [TemperatureDisplaySensor],
        cpuUsage: Double?,
        gpuUsage: Double?,
        topApps: [TopAppMetrics],
        thermalState: ProcessInfo.ThermalState = .nominal
    ) -> [TemperatureInsight] {
        let medians: [SensorGroup: Double] = Dictionary(uniqueKeysWithValues: SensorGroup.allCasesForTemperatureDisplay.compactMap { group -> (SensorGroup, Double)? in
            let values = sensors.filter { $0.group == group }.map(\.celsius).sorted()
            guard !values.isEmpty else { return nil }
            let middle = values.count / 2
            let median = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) / 2
                : values[middle]
            return (group, median)
        })
        let topProcess = topApps.first.map { String($0.name.prefix(18)) }

        return sensors.compactMap { sensor -> TemperatureInsight? in
            let deviation = sensor.celsius - (medians[sensor.group] ?? sensor.celsius)
            let isAbsoluteWarning = sensor.celsius >= 80
            let isGroupOutlier = sensor.celsius >= 65 && deviation >= 15
            guard isAbsoluteWarning || isGroupOutlier else { return nil }

            let severity: TemperatureInsight.Severity = sensor.celsius >= 90 ? .critical : .warning
            let context = temperatureContext(
                for: sensor,
                deviation: deviation,
                cpuUsage: cpuUsage,
                gpuUsage: gpuUsage,
                topProcess: topProcess
            )
            let absoluteScore = max(0, (sensor.celsius - 75) / 10)
            let deviationScore = max(0, deviation / 15)
            return TemperatureInsight(
                sensor: sensor,
                severity: severity,
                deviationFromGroupMedian: deviation,
                assessment: temperatureAssessment(
                    for: sensor,
                    cpuUsage: cpuUsage,
                    gpuUsage: gpuUsage,
                    thermalState: thermalState
                ),
                location: temperatureLocation(for: sensor),
                reason: context.reason,
                solution: context.solution,
                score: absoluteScore + deviationScore
            )
        }
        .sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue > $1.severity.rawValue
            }
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            return $0.sensor.celsius > $1.sensor.celsius
        }
    }

    private static func temperatureAssessment(
        for sensor: TemperatureDisplaySensor,
        cpuUsage: Double?,
        gpuUsage: Double?,
        thermalState: ProcessInfo.ThermalState
    ) -> String {
        if thermalState == .serious || thermalState == .critical {
            return "System heat is elevated; not normal if sustained."
        }

        let relevantLoad: Double?
        switch sensor.group {
        case .cpu: relevantLoad = cpuUsage
        case .gpu: relevantLoad = gpuUsage
        case .hotspot, .other: relevantLoad = max(cpuUsage ?? 0, gpuUsage ?? 0)
        }

        if sensor.celsius >= 90 {
            return (relevantLoad ?? 0) >= 0.70
                ? "Very hot; plausible briefly under heavy load."
                : "Unusual at this load; not normal if sustained."
        }
        if (relevantLoad ?? 0) >= 0.70 || thermalState == .fair {
            return "Warm but plausible under sustained load."
        }
        return "Unusual for the current workload; monitor it."
    }

    private static func temperatureLocation(for sensor: TemperatureDisplaySensor) -> String {
        switch sensor.group {
        case .cpu:
            return "CPU region of SoC; exact point not exposed."
        case .gpu:
            return "GPU region of SoC; exact point not exposed."
        case .hotspot:
            return "Thermal-module hotspot; exact point not exposed."
        case .other:
            return "Internal component; exact point not exposed."
        }
    }

    private static func temperatureContext(
        for sensor: TemperatureDisplaySensor,
        deviation: Double,
        cpuUsage: Double?,
        gpuUsage: Double?,
        topProcess: String?
    ) -> (reason: String, solution: String) {
        switch sensor.group {
        case .cpu:
            if let cpuUsage, cpuUsage >= 0.70 {
                let process = topProcess.map { "; top: \($0)" } ?? ""
                return (
                    "CPU load \(Int((cpuUsage * 100).rounded()))%\(process).",
                    topProcess.map { "Pause \($0) or reduce sustained work." }
                        ?? "Reduce sustained CPU work and clear the vents."
                )
            }
            if deviation >= 15 {
                return (
                    "\(Int(deviation.rounded()))°C above nearby CPU sensors.",
                    "Wait 2 min; use a hard surface; check airflow."
                )
            }
            return (
                "The CPU package is uniformly hot.",
                "Reduce workload or use Auto Boost; keep vents clear."
            )
        case .gpu:
            if let gpuUsage, gpuUsage >= 0.70 {
                return (
                    "GPU load \(Int((gpuUsage * 100).rounded()))% is heating this region.",
                    "Pause graphics, video, or 3D work; check airflow."
                )
            }
            return (
                deviation >= 15 ? "\(Int(deviation.rounded()))°C above nearby GPU sensors." : "GPU heat is elevated.",
                "Pause graphics-heavy work and use a hard surface."
            )
        case .hotspot:
            return (
                "Heat is concentrated near a chip or power area.",
                "Improve airflow and reduce sustained system load."
            )
        case .other:
            return (
                deviation >= 15 ? "\(Int(deviation.rounded()))°C above similar sensors." : "A system component is unusually warm.",
                "Check airflow; unplug heavy peripherals; monitor it."
            )
        }
    }

    static func synchronizedTargets(sourceIndex: Int, rpm: Double, capabilities: [FanCapability]) -> [FanTarget] {
        guard let source = capabilities.first(where: { $0.index == sourceIndex }), source.maximumRPM > source.minimumRPM else { return [] }
        let demand = min(1, max(0, (rpm - source.minimumRPM) / (source.maximumRPM - source.minimumRPM)))
        return capabilities.map { fan in
            FanTarget(index: fan.index, rpm: fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * demand)
        }
    }

    @objc private func modeChanged() {
        guard let mode = FanControlMode(rawValue: modeControl.selectedSegment) else { return }
        onModeChange?(mode)
    }

    @objc private func restoreSystem() { onRestoreSystem?() }
    @objc private func enableHelper() { onEnableHelper?() }

    @objc private func toggleLink() {
        fansLinked.toggle()
        updateLinkAppearance()
        guard fansLinked, let first = capabilities.first else { return }
        let rpm = manualDraft[first.index] ?? first.minimumRPM
        previewManualTarget(index: first.index, rpm: rpm)
        commitManualTarget(index: first.index, rpm: rpm)
    }

    @objc private func showProfileMenu() {
        let menu = NSMenu(title: "Auto Boost Profile")
        for profile in FanResponseProfile.allCases {
            let item = NSMenuItem(title: profile.displayName, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.rawValue
            item.state = profile == currentProfile ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let rules = NSMenuItem(title: "Smart Rules", action: #selector(toggleSmartRules(_:)), keyEquivalent: "")
        rules.target = self
        rules.state = smartRulesEnabled ? .on : .off
        rules.toolTip = smartRulesEnabled ? smartRulesReason : "Disabled by default; only adjusts Auto Boost profiles"
        menu.addItem(rules)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settingsButton.bounds.maxY + 2), in: settingsButton)
    }

    @objc private func toggleSmartRules(_ sender: NSMenuItem) {
        smartRulesEnabled.toggle()
        onSmartRulesChange?(smartRulesEnabled)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let profile = FanResponseProfile(rawValue: rawValue)
        else { return }
        currentProfile = profile
        onProfileChange?(profile)
    }

    private func updateRow(_ row: FanRPMRowView, index: Int, state: FanControlViewState, target: Double?, editable: Bool) {
        let capability = capabilities.first { $0.index == index }
        let actual = index < state.actualRPM.count ? state.actualRPM[index] : nil
        row.update(capability: capability, actualRPM: actual, targetRPM: target, isEditable: editable)
    }

    private func previewManualTarget(index: Int, rpm: Double) {
        guard modeControl.selectedSegment == FanControlMode.manual.rawValue else { return }
        if fansLinked {
            for target in Self.synchronizedTargets(sourceIndex: index, rpm: rpm, capabilities: capabilities) {
                manualDraft[target.index] = target.rpm
            }
        } else {
            manualDraft[index] = rpm
        }
        leftRow.setPreviewTarget(manualDraft[0])
        rightRow.setPreviewTarget(manualDraft[1])
    }

    private func commitManualTarget(index: Int, rpm: Double) {
        previewManualTarget(index: index, rpm: rpm)
        let targets = capabilities.compactMap { fan -> FanTarget? in
            guard let rpm = manualDraft[fan.index] else { return nil }
            return FanTarget(index: fan.index, rpm: rpm)
        }
        guard targets.count == capabilities.count else { return }
        onManualTargetsChange?(targets)
    }

    private func updateHelperFeedback(_ state: FanControlViewState) {
        helperProgress.stopAnimation(nil)
        helperButton.image = nil
        helperButton.contentTintColor = nil

        switch state.helperFeedback {
        case .working:
            helperProgress.startAnimation(nil)
            helperButton.title = "Authorizing…"
            helperButton.isEnabled = false
        case .failed:
            helperButton.title = state.helperRegistration == "Installed" ? "Repair Helper…" : "Enable Helper…"
            helperButton.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "Helper unavailable")
            helperButton.imagePosition = .imageLeading
            helperButton.contentTintColor = .systemOrange
            helperButton.isEnabled = true
        case .confirmed:
            helperButton.title = "Helper Ready"
            helperButton.isEnabled = false
        case .idle:
            helperButton.title = state.helperRegistration == "Installed" ? "Confirm Helper…" : "Enable Helper…"
            helperButton.isEnabled = true
        }

        showsHelperAuthorization = !state.helperReady
        helperButton.isHidden = !showsHelperAuthorization
        helperProgress.isHidden = !showsHelperAuthorization
    }

    private func configureIconButton(_ button: NSButton, symbol: String, accessibilityLabel: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.isBordered = false
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func updateLinkAppearance() {
        let symbol = fansLinked ? "link" : "link.badge.plus"
        linkButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: fansLinked ? "Fan targets linked" : "Fan targets independent")
        linkButton.contentTintColor = fansLinked ? .controlAccentColor : .secondaryLabelColor
        linkButton.setAccessibilityValue(fansLinked ? "Linked" : "Independent")
    }

    private func drawSeparator(y: CGFloat, inset: CGFloat = 10) {
        NSColor.separatorColor.withAlphaComponent(0.42).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: inset, y: y))
        line.line(to: NSPoint(x: bounds.width - inset, y: y))
        line.lineWidth = 0.5
        line.stroke()
    }

    private func drawTemperatures(in dirtyRect: NSRect) {
        guard bounds.height > Self.preferredSize.height else { return }
        let temperatureBounds = NSRect(
            x: 10,
            y: Self.temperatureOriginY - 4,
            width: bounds.width - 20,
            height: bounds.height - Self.temperatureOriginY
        )
        if dirtyRect.intersects(temperatureBounds) {
            NSColor.windowBackgroundColor.setFill()
            NSIntersectionRect(dirtyRect, temperatureBounds).fill()
        }
        var y = Self.temperatureOriginY
        let headerRect = NSRect(x: 14, y: y, width: bounds.width - 28, height: Self.temperatureHeaderHeight)
        if dirtyRect.intersects(headerRect) {
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: 14, y: y))
            separator.line(to: NSPoint(x: bounds.width - 14, y: y))
            separator.lineWidth = 0.6
            separator.stroke()

            if let icon = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)) {
                icon.draw(in: NSRect(x: 20, y: y + 9, width: 18, height: 18))
            }
            drawTemperatureText(
                "Temperatures",
                in: NSRect(x: 44, y: y + 8, width: 170, height: 20),
                font: .systemFont(ofSize: 13, weight: .semibold),
                color: .labelColor
            )
            drawTemperatureText(
                "\(temperatureSensorCount) live sensors",
                in: NSRect(x: bounds.width - 138, y: y + 10, width: 112, height: 16),
                font: .systemFont(ofSize: 8.8),
                color: .tertiaryLabelColor,
                alignment: .right
            )
        }
        y += Self.temperatureHeaderHeight

        if let insight = temperatureInsights.first {
            let cardRect = NSRect(
                x: 16,
                y: y + 2,
                width: bounds.width - 32,
                height: Self.temperatureInsightHeight - 6
            )
            if dirtyRect.intersects(cardRect) {
                let color: NSColor = insight.severity == .critical ? .systemRed : .systemOrange
                color.withAlphaComponent(0.11).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9).fill()
                color.withAlphaComponent(0.65).setStroke()
                let border = NSBezierPath(roundedRect: cardRect, xRadius: 9, yRadius: 9)
                border.lineWidth = 0.8
                border.stroke()

                if let icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) {
                    icon.draw(in: NSRect(x: 25, y: y + 10, width: 15, height: 15))
                }
                drawTemperatureText(
                    "\(insight.sensor.name) · \(insight.sensor.key)",
                    in: NSRect(x: 46, y: y + 8, width: 205, height: 17),
                    font: .systemFont(ofSize: 10.5, weight: .semibold),
                    color: .labelColor
                )
                drawTemperatureText(
                    String(format: "%.1f°C", insight.sensor.celsius),
                    in: NSRect(x: bounds.width - 102, y: y + 7, width: 72, height: 18),
                    font: .monospacedDigitSystemFont(ofSize: 11.2, weight: .bold),
                    color: color,
                    alignment: .right
                )
                drawTemperatureText(
                    "Assessment: \(insight.assessment)",
                    in: NSRect(x: 26, y: y + 28, width: bounds.width - 52, height: 14),
                    font: .systemFont(ofSize: 8.4, weight: .medium),
                    color: color
                )
                drawTemperatureText(
                    "Location: \(insight.location)",
                    in: NSRect(x: 26, y: y + 44, width: bounds.width - 52, height: 14),
                    font: .systemFont(ofSize: 8.3),
                    color: .secondaryLabelColor
                )
                drawTemperatureText(
                    "Likely: \(insight.reason)",
                    in: NSRect(x: 26, y: y + 60, width: bounds.width - 52, height: 14),
                    font: .systemFont(ofSize: 8.3),
                    color: .secondaryLabelColor
                )
                drawTemperatureText(
                    "Try: \(insight.solution)",
                    in: NSRect(x: 26, y: y + 76, width: bounds.width - 52, height: 14),
                    font: .systemFont(ofSize: 8.7, weight: .medium),
                    color: .labelColor
                )
            }
            y += Self.temperatureInsightHeight
        }

        var previousGroup: SensorGroup?
        let unusualKeys = Set(temperatureInsights.dropFirst().map(\.sensor.key))
        for sensor in temperatureSensors {
            if sensor.group != previousGroup {
                let groupRect = NSRect(x: 14, y: y, width: bounds.width - 28, height: Self.temperatureGroupHeight)
                if dirtyRect.intersects(groupRect) {
                    NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
                    NSBezierPath(roundedRect: groupRect.insetBy(dx: 4, dy: 2), xRadius: 5, yRadius: 5).fill()
                    drawTemperatureText(
                        sensor.groupTitle,
                        in: NSRect(x: 24, y: y + 4, width: 180, height: 14),
                        font: .systemFont(ofSize: 8.5, weight: .semibold),
                        color: .secondaryLabelColor
                    )
                }
                y += Self.temperatureGroupHeight
                previousGroup = sensor.group
            }

            let rowRect = NSRect(x: 20, y: y, width: bounds.width - 40, height: Self.temperatureRowHeight)
            if dirtyRect.intersects(rowRect) {
                if unusualKeys.contains(sensor.key) {
                    NSColor.systemOrange.withAlphaComponent(0.08).setFill()
                    NSBezierPath(roundedRect: rowRect, xRadius: 4, yRadius: 4).fill()
                }
                drawTemperatureText(
                    sensor.name,
                    in: NSRect(x: 28, y: y + 2, width: 145, height: 15),
                    font: .systemFont(ofSize: 10.2),
                    color: .labelColor
                )
                drawTemperatureText(
                    sensor.key,
                    in: NSRect(x: 174, y: y + 3, width: 46, height: 14),
                    font: .monospacedSystemFont(ofSize: 8.3, weight: .regular),
                    color: .tertiaryLabelColor
                )
                let healthColor: NSColor = sensor.health.confidence == .live ? .systemGreen : .systemOrange
                drawTemperatureText(
                    sensor.health.confidence.rawValue.uppercased(),
                    in: NSRect(x: 220, y: y + 3, width: 48, height: 14),
                    font: .systemFont(ofSize: 6.8, weight: .semibold),
                    color: healthColor
                )
                let temperatureColor: NSColor = sensor.celsius >= 90
                    ? .systemRed
                    : sensor.celsius >= 80 ? .systemOrange : .labelColor
                drawTemperatureText(
                    String(format: "%.1f°C", sensor.celsius),
                    in: NSRect(x: bounds.width - 98, y: y + 1, width: 70, height: 16),
                    font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                    color: temperatureColor,
                    alignment: .right
                )
            }
            y += Self.temperatureRowHeight
        }
    }

    private func drawTemperatureText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        ).draw(in: rect)
    }

    private func updateHover(at point: NSPoint) {
        let target: NSRect?
        if let segment = hoveredSegment(at: point) {
            target = segment
        } else if !stopButton.isHidden, stopButton.isEnabled, stopButton.frame.contains(point) {
            target = stopButton.frame.insetBy(dx: 3, dy: 0)
        } else if !linkButton.isHidden, linkButton.isEnabled, linkButton.frame.contains(point) {
            target = linkButton.frame.insetBy(dx: 3, dy: 0)
        } else if settingsButton.frame.contains(point) {
            target = settingsButton.frame.insetBy(dx: 2, dy: 0)
        } else if showsHelperAuthorization, helperButton.isEnabled, helperButton.frame.contains(point) {
            target = helperButton.frame.insetBy(dx: 8, dy: 0)
        } else {
            target = nil
        }

        guard let target else {
            hoverTargetOpacity = 0
            startHoverAnimationIfNeeded()
            return
        }
        if hoverOpacity < 0.01 { hoverRect = target }
        hoverTargetRect = target
        hoverTargetOpacity = 1
        startHoverAnimationIfNeeded()
    }

    private func hoveredSegment(at point: NSPoint) -> NSRect? {
        guard modeControl.frame.contains(point), modeControl.segmentCount > 0 else { return nil }
        let width = modeControl.frame.width / CGFloat(modeControl.segmentCount)
        let index = min(modeControl.segmentCount - 1, max(0, Int((point.x - modeControl.frame.minX) / width)))
        guard modeControl.isEnabled(forSegment: index) else { return nil }
        return NSRect(x: modeControl.frame.minX + CGFloat(index) * width + 5, y: modeControl.frame.minY, width: width - 10, height: modeControl.frame.height)
    }

    private func startHoverAnimationIfNeeded() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hoverAnimationTimer?.invalidate(); hoverAnimationTimer = nil
            hoverRect = hoverTargetRect; hoverOpacity = hoverTargetOpacity
            needsDisplay = true
            return
        }
        guard hoverAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let easing: CGFloat = 0.22
            self.hoverRect.origin.x += (self.hoverTargetRect.origin.x - self.hoverRect.origin.x) * easing
            self.hoverRect.origin.y += (self.hoverTargetRect.origin.y - self.hoverRect.origin.y) * easing
            self.hoverRect.size.width += (self.hoverTargetRect.size.width - self.hoverRect.size.width) * easing
            self.hoverRect.size.height += (self.hoverTargetRect.size.height - self.hoverRect.size.height) * easing
            self.hoverOpacity += (self.hoverTargetOpacity - self.hoverOpacity) * easing
            self.needsDisplay = true

            let settled = abs(self.hoverRect.minX - self.hoverTargetRect.minX) < 0.1
                && abs(self.hoverRect.minY - self.hoverTargetRect.minY) < 0.1
                && abs(self.hoverRect.width - self.hoverTargetRect.width) < 0.1
                && abs(self.hoverRect.height - self.hoverTargetRect.height) < 0.1
                && abs(self.hoverOpacity - self.hoverTargetOpacity) < 0.01
            if settled {
                self.hoverRect = self.hoverTargetRect
                self.hoverOpacity = self.hoverTargetOpacity
                self.hoverAnimationTimer = nil
                timer.invalidate()
            }
        }
        timer.tolerance = 0.003
        RunLoop.main.add(timer, forMode: .common)
        hoverAnimationTimer = timer
    }
}

final class FanRPMRowView: NSView {
    let slider = FanRPMControl()
    var onPreview: ((Int, Double) -> Void)?
    var onCommit: ((Int, Double) -> Void)?

    private let sideLabel: NSTextField
    private let rpmLabel = NSTextField(labelWithString: "— RPM")
    private let minimumLabel = NSTextField(labelWithString: "— RPM")
    private let maximumLabel = NSTextField(labelWithString: "— RPM")
    private let fanIndex: Int

    var accessibilitySummary: String { "\(sideLabel.stringValue) \(rpmLabel.stringValue)" }
    override var isFlipped: Bool { true }

    init(side: String, fanIndex: Int) {
        self.sideLabel = NSTextField(labelWithString: side)
        self.fanIndex = fanIndex
        super.init(frame: .zero)
        [sideLabel, rpmLabel, minimumLabel, maximumLabel, slider].forEach(addSubview)

        sideLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        rpmLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        [minimumLabel, maximumLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
        maximumLabel.alignment = .right
        slider.setAccessibilityLabel("\(side) fan target")
        slider.onPreview = { [weak self] rpm in
            guard let self else { return }
            self.onPreview?(self.fanIndex, rpm)
        }
        slider.onCommit = { [weak self] rpm in
            guard let self else { return }
            self.onCommit?(self.fanIndex, rpm)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        sideLabel.frame = NSRect(x: 0, y: 1, width: 68, height: 16)
        rpmLabel.frame = NSRect(x: 0, y: 20, width: 68, height: 15)
        slider.frame = NSRect(x: 73, y: 3, width: bounds.width - 73, height: 18)
        minimumLabel.frame = NSRect(x: 73, y: 25, width: 84, height: 14)
        maximumLabel.frame = NSRect(x: bounds.width - 88, y: 25, width: 88, height: 14)
    }

    func update(capability: FanCapability?, actualRPM: Double?, targetRPM: Double?, isEditable: Bool) {
        rpmLabel.stringValue = actualRPM.map { "\(Int($0.rounded())) RPM" } ?? "— RPM"
        minimumLabel.stringValue = capability.map { "\(Int($0.minimumRPM.rounded())) RPM" } ?? "— RPM"
        maximumLabel.stringValue = capability.map { "\(Int($0.maximumRPM.rounded())) RPM" } ?? "— RPM"
        slider.minimumRPM = capability?.minimumRPM ?? 0
        slider.maximumRPM = capability?.maximumRPM ?? 8_000
        slider.actualRPM = actualRPM
        slider.showsTarget = targetRPM != nil
        if let targetRPM { slider.targetRPM = targetRPM }
        slider.isEditable = isEditable && capability != nil
        slider.isEnabled = slider.isEditable
    }

    func setPreviewTarget(_ rpm: Double?) {
        guard let rpm else { return }
        slider.targetRPM = rpm
    }
}

final class FanRPMControl: NSControl {
    var onPreview: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    var minimumRPM: Double = 0 { didSet { updateLayers() } }
    var maximumRPM: Double = 8_000 { didSet { updateLayers() } }
    var targetRPM: Double = 0 { didSet { updateLayers() } }
    var actualRPM: Double? {
        didSet { updateLayers(animateActual: oldValue != nil && !isHiddenOrHasHiddenAncestor) }
    }
    var showsTarget = false { didSet { updateLayers() } }
    var isEditable = false { didSet { updateLayers() } }
    private(set) var isInteracting = false

    private let trackLayer = CALayer()
    private let actualLayer = CALayer()
    private let targetLayer = CALayer()
    private let thumbLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEditable && isEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        [trackLayer, actualLayer, targetLayer, thumbLayer].forEach { layer?.addSublayer($0) }
        actualLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        targetLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        thumbLayer.shadowOffset = CGSize(width: 0, height: 1)
        thumbLayer.shadowRadius = 2
        thumbLayer.shadowOpacity = 0.18
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        [trackLayer, actualLayer, targetLayer, thumbLayer].forEach { $0.contentsScale = scale }
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEditable else { return }
        animateThumb(scale: 1.08)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isInteracting else { return }
        animateThumb(scale: 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable, isEnabled else { return }
        isInteracting = true
        window?.makeFirstResponder(self)
        animateThumb(scale: 1.15)
        updateTarget(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteracting else { return }
        updateTarget(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteracting else { return }
        updateTarget(with: event)
        isInteracting = false
        animateThumb(scale: 1.08)
        onCommit?(targetRPM)
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable else { return super.keyDown(with: event) }
        let delta: Double
        switch event.keyCode {
        case 123, 125: delta = -100
        case 124, 126: delta = 100
        default: return super.keyDown(with: event)
        }
        targetRPM = clamped(targetRPM + delta)
        onPreview?(targetRPM)
        onCommit?(targetRPM)
    }

    private var trackRect: CGRect {
        CGRect(x: 6, y: bounds.midY - 3, width: max(0, bounds.width - 12), height: 6)
    }

    private func updateTarget(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let progress = min(1, max(0, (point.x - trackRect.minX) / max(1, trackRect.width)))
        targetRPM = clamped(minimumRPM + Double(progress) * (maximumRPM - minimumRPM))
        onPreview?(targetRPM)
    }

    private func clamped(_ rpm: Double) -> Double {
        min(maximumRPM, max(minimumRPM, rpm))
    }

    private func progress(for rpm: Double?) -> CGFloat {
        guard let rpm, maximumRPM > minimumRPM else { return 0 }
        return CGFloat(min(1, max(0, (rpm - minimumRPM) / (maximumRPM - minimumRPM))))
    }

    private func updateLayers(animateActual: Bool = false) {
        guard bounds.width > 0 else { return }
        let track = trackRect
        let oldActualWidth = actualLayer.presentation()?.bounds.width ?? actualLayer.bounds.width
        let actualWidth = track.width * progress(for: actualRPM)
        let targetWidth = track.width * progress(for: targetRPM)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = track
        trackLayer.cornerRadius = track.height / 2
        actualLayer.position = CGPoint(x: track.minX, y: track.midY + 1)
        actualLayer.bounds = CGRect(x: 0, y: 0, width: actualWidth, height: 5)
        actualLayer.cornerRadius = 2.5
        targetLayer.position = CGPoint(x: track.minX, y: track.midY - 1)
        targetLayer.bounds = CGRect(x: 0, y: 0, width: targetWidth, height: 2)
        targetLayer.cornerRadius = 1
        targetLayer.isHidden = !showsTarget
        let thumbSize: CGFloat = 13
        let thumbX = track.minX + targetWidth
        thumbLayer.frame = CGRect(x: thumbX - thumbSize / 2, y: track.midY - thumbSize / 2, width: thumbSize, height: thumbSize)
        thumbLayer.cornerRadius = thumbSize / 2
        thumbLayer.isHidden = !showsTarget || !isEditable
        CATransaction.commit()

        if animateActual, abs(oldActualWidth - actualWidth) > 0.5 {
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = oldActualWidth
            animation.toValue = actualWidth
            animation.duration = 0.34
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            actualLayer.add(animation, forKey: "rpm-progress")
        }

        setAccessibilityMinValue(minimumRPM as NSNumber)
        setAccessibilityMaxValue(maximumRPM as NSNumber)
        setAccessibilityValue(targetRPM as NSNumber)
    }

    private func updateColors() {
        trackLayer.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.20).cgColor
        actualLayer.backgroundColor = NSColor.systemGreen.cgColor
        targetLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        thumbLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        thumbLayer.borderColor = NSColor.separatorColor.cgColor
        thumbLayer.borderWidth = 0.6
        thumbLayer.shadowColor = NSColor.black.cgColor
    }

    private func animateThumb(scale: CGFloat) {
        guard !thumbLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        thumbLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }
}

final class SpinningFanView: NSView {
    private let glyphImage: NSImage? = {
        let size = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let color = NSImage.SymbolConfiguration(hierarchicalColor: .systemBlue)
        return NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil)?
            .withSymbolConfiguration(size.applying(color))
    }()
    private var animationEnabled = true
    private var latestRPM: Double?
    private let glyphLayer = CALayer()
    private var isRotating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphLayer.contentsGravity = .resizeAspect
        glyphLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(glyphLayer)
        updateGlyphContents()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.bounds = CGRect(origin: .zero, size: bounds.insetBy(dx: 2, dy: 2).size)
        glyphLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    static func rotationTransform(in bounds: NSRect, degrees: CGFloat) -> NSAffineTransform {
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.midX, yBy: bounds.midY)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
        return transform
    }

    func update(rpm: Double?) {
        latestRPM = rpm
        guard animationEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let rpm,
              rpm > 50 else {
            stopAnimation()
            return
        }
        startAnimationIfNeeded(rpm: rpm)
    }

    func setAnimationEnabled(_ enabled: Bool) {
        guard animationEnabled != enabled else { return }
        animationEnabled = enabled
        update(rpm: latestRPM)
    }

    private func startAnimationIfNeeded(rpm: Double) {
        if !isRotating {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = Double.pi * 2
            animation.duration = 1
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            glyphLayer.add(animation, forKey: "fan-rotation")
            isRotating = true
        }
        let turnsPerSecond = min(3.2, max(0.22, rpm / 2_400))
        glyphLayer.speed = Float(turnsPerSecond)
    }

    private func stopAnimation() {
        glyphLayer.removeAnimation(forKey: "fan-rotation")
        glyphLayer.speed = 1
        glyphLayer.transform = CATransform3DIdentity
        isRotating = false
    }

    private func updateGlyphContents() {
        guard let glyphImage else { return }
        var rect = NSRect(origin: .zero, size: glyphImage.size)
        glyphLayer.contents = glyphImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        glyphLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyphLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlyphContents()
        if let rpm = latestRPM {
            update(rpm: rpm)
        }
    }
}
