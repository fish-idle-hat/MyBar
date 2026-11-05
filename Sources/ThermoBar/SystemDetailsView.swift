import AppKit

final class SystemDetailsView: NSView {
    static let preferredSize = NSSize(width: 360, height: 224)
    static let systemSectionHeight: CGFloat = 420
    private static let systemPageOffset: CGFloat = 24
    private static let batteryOriginY: CGFloat = 230
    private static let tabBarHeight: CGFloat = 36
    private static let contentOriginY: CGFloat = 60
    private static let resizeHandleHeight: CGFloat = 14
    private static let maximumResizableHeight: CGFloat = 680
    static let tabWidthWeights: [CGFloat] = [1, 1.14, 0.9, 0.8, 1.11]

    private enum Tab: Int, CaseIterable {
        case system
        case networkAndApps
        case sound
        case fans
        case mood

        var title: String {
            switch self {
            case .system: "System"
            case .networkAndApps: "Net+Apps"
            case .sound: "Sound"
            case .fans: "Fans"
            case .mood: "Mood\nCompass"
            }
        }

        var titleFontSize: CGFloat {
            switch self {
            case .networkAndApps: 9.0
            case .system, .sound, .fans: 9.3
            case .mood: 8.2
            }
        }
    }

    static var tabCount: Int { Tab.allCases.count }

    private var snapshot: HardwareSnapshot?
    private var history: [HistoricalMetricsPoint] = []
    private var statusMessage = "Collecting system metrics…"
    private var selectedTab: Tab = .system
    private enum SystemPage: Int { case overview, insights, pet }
    private var systemPage: SystemPage = .overview
    private let systemPageControl = HoverSegmentedControl(labels: ["Overview", "Insights", "Pet"], trackingMode: .selectOne, target: nil, action: nil)
    private weak var embeddedPetView: PetControlView?
    private var menuVisible = false
    private(set) var selectedHistoryRange: MetricHistoryRange = .day
    var onHistoryRangeChange: ((MetricHistoryRange) -> Void)?
    var onSectionChange: (() -> Void)?
    var onExportDiagnostics: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var onOpenReplay: (() -> Void)?
    var onOpenEnergyApp: ((TopAppMetrics, Bool) -> Void)?
    private let energyAppButtons = (0..<3).map { _ in EnergyAppActionButton(frame: .zero) }
    private var trackingArea: NSTrackingArea?
    private var tabHoverPosition: CGFloat = 0
    private var tabHoverTarget: CGFloat = 0
    private var tabHoverOpacity: CGFloat = 0
    private var tabHoverTargetOpacity: CGFloat = 0
    private var rangeHoverPosition: CGFloat = 0
    private var rangeHoverTarget: CGFloat = 0
    private var rangeHoverOpacity: CGFloat = 0
    private var rangeHoverTargetOpacity: CGFloat = 0
    private var hoverAnimationTimer: Timer?
    private weak var embeddedFanControlView: FanControlView?
    private weak var embeddedFanScrollView: NSScrollView?
    private weak var embeddedSoundControlView: SoundControlView?
    private weak var embeddedSoundScrollView: NSScrollView?
    private weak var embeddedMoodView: MoodCompassView?
    private weak var embeddedMoodScrollView: NSScrollView?
    private let moodTabButton = NSButton(title: "", target: nil, action: nil)
    private let soundTabButton = NSButton(title: "", target: nil, action: nil)
    private var moodHeight: CGFloat = 440
    private let diagnosticButton = NSButton(title: "", target: nil, action: nil)
    private let resizeHandle = BottomResizeHandleView()
    private var soundHeight = SoundControlView.preferredSize.height + tabBarHeight + resizeHandleHeight
    private var fanHeight = preferredSize.height
    private var thermalPrediction: ThermalPrediction?
    private var incidents: [MonitoringIncident] = []
    private var monitoringMode: MonitoringMode = .balanced
    private var personalRange: PersonalBaseline.Range?
    private var replayPanel: NSPanel?

    func updatePersonalRange(_ range: PersonalBaseline.Range?) {
        personalRange = range
        if isInsightsTabSelected { needsDisplay = true }
    }

    var isFansTabSelected: Bool { selectedTab == .fans }
    var isSoundTabSelected: Bool { selectedTab == .sound }
    var isInsightsTabSelected: Bool { selectedTab == .system && systemPage == .insights }
    var isMoodTabSelected: Bool { selectedTab == .mood }
    var isPetPageSelected: Bool { selectedTab == .system && systemPage == .pet }

    func installPetView(_ view: PetControlView) {
        embeddedPetView?.removeFromSuperview()
        embeddedPetView = view
        view.isHidden = !isPetPageSelected
        addSubview(view)
        needsLayout = true
    }
    func setMenuVisible(_ visible: Bool) {
        menuVisible = visible
        embeddedPetView?.setPageVisible(visible && isPetPageSelected)
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        frame.size.height = Self.systemSectionHeight
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MyBar system details")
        configureDiagnosticButton()
        configureSystemPages()
        configureResizeHandle()
        configureEnergyAppButtons()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        frame.size.height = Self.systemSectionHeight
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MyBar system details")
        configureDiagnosticButton()
        configureSystemPages()
        configureResizeHandle()
        configureEnergyAppButtons()
    }

    deinit {
        hoverAnimationTimer?.invalidate()
    }

    func update(snapshot: HardwareSnapshot, history: [HistoricalMetricsPoint]) {
        self.history = history
        update(snapshot: snapshot)
    }

    func update(snapshot: HardwareSnapshot) {
        self.snapshot = snapshot
        statusMessage = ""
        // Mood owns its presentation; unrelated two-second sensor polls must not
        // redraw its charts or replace its accessibility value.
        guard selectedTab != .mood else { return }
        setAccessibilityValue(accessibilitySummary(snapshot))
        updateEnergyAppButtons()
        needsDisplay = true
    }

    private func configureEnergyAppButtons() {
        for button in energyAppButtons {
            button.onOpen = { [weak self] app, reveal in self?.onOpenEnergyApp?(app, reveal) }
            button.isHidden = true
            addSubview(button)
        }
    }

    private func updateEnergyAppButtons() {
        let apps = snapshot.map { Self.topEnergyApps(from: $0.topApps) } ?? []
        for (index, button) in energyAppButtons.enumerated() {
            button.isHidden = selectedTab != .system || systemPage != .overview || snapshot?.batteryMetrics == nil || index >= apps.count
            guard index < apps.count else { button.app = nil; continue }
            let app = apps[index]
            button.app = app
            button.isEnabled = app.applicationURL != nil || app.executableURL != nil
            button.frame = NSRect(x: 234, y: Self.batteryOriginY + Self.systemPageOffset + 81 + CGFloat(index * 22), width: 112, height: 22)
            let path = app.applicationURL?.path ?? app.executableURL?.path ?? "Location unavailable"
            button.toolTip = "\(app.name)\nClick to open the app or reveal its process in Finder.\nOption-click to reveal in Finder.\n\(path)"
            button.setAccessibilityLabel("Open \(app.name) or reveal in Finder")
        }
    }

    func updateHistory(_ history: [HistoricalMetricsPoint]) {
        self.history = history
        if selectedTab != .mood { needsDisplay = true }
    }

    func updateIntelligence(
        prediction: ThermalPrediction?,
        incidents: [MonitoringIncident],
        mode: MonitoringMode
    ) {
        thermalPrediction = prediction
        self.incidents = incidents
        monitoringMode = mode
        if isInsightsTabSelected { needsDisplay = true }
    }

    private func configureSystemPages() {
        systemPageControl.selectedSegment = 0
        systemPageControl.controlSize = .small
        systemPageControl.segmentStyle = .rounded
        systemPageControl.font = .systemFont(ofSize: 9)
        systemPageControl.target = self
        systemPageControl.action = #selector(systemPageChanged)
        systemPageControl.setAccessibilityLabel("System section")
        addSubview(systemPageControl)
    }

    @objc private func systemPageChanged() { selectSystemPage(at: systemPageControl.selectedSegment) }

    func selectSystemPage(at index: Int) {
        guard let page = SystemPage(rawValue: index) else { return }
        systemPage = page
        systemPageControl.selectedSegment = index
        selectTab(at: Tab.system.rawValue)
    }

    private func configureDiagnosticButton() {
        diagnosticButton.isBordered = false
        diagnosticButton.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: "Export diagnostic report"
        )
        diagnosticButton.imagePosition = .imageOnly
        diagnosticButton.contentTintColor = .secondaryLabelColor
        diagnosticButton.target = self
        diagnosticButton.action = #selector(exportDiagnostics)
        diagnosticButton.isHidden = true
        diagnosticButton.toolTip = "Create a privacy-safe MyBar diagnostic report"
        diagnosticButton.setAccessibilityLabel("Export diagnostic report")
        addSubview(diagnosticButton)
    }

    private func configureResizeHandle() {
        resizeHandle.isHidden = true
        resizeHandle.onResize = { [weak self] height in
            self?.resizeSelectedSection(to: height)
        }
        addSubview(resizeHandle)
    }

    override func layout() {
        super.layout()
        diagnosticButton.frame = NSRect(x: bounds.width - 34, y: 36, width: 22, height: 22)
        systemPageControl.frame = NSRect(x: 10, y: 36, width: 240, height: 22)
        embeddedPetView?.frame = NSRect(x: 0, y: 62, width: bounds.width, height: PetControlView.preferredHeight)
        resizeHandle.frame = NSRect(
            x: 0,
            y: bounds.height - Self.resizeHandleHeight,
            width: bounds.width,
            height: Self.resizeHandleHeight
        )

        let reservesResizeHandle = selectedTab == .sound || selectedTab == .fans || selectedTab == .mood
        let viewportHeight = max(
            0,
            bounds.height - Self.tabBarHeight - (reservesResizeHandle ? Self.resizeHandleHeight : 0)
        )
        let viewportFrame = NSRect(x: 0, y: Self.tabBarHeight, width: bounds.width, height: viewportHeight)
        embeddedFanScrollView?.frame = viewportFrame
        embeddedSoundScrollView?.frame = viewportFrame
        embeddedMoodScrollView?.frame = viewportFrame
        embeddedMoodView?.frame.size = NSSize(width: bounds.width, height: max(viewportHeight, MoodCompassView.preferredSize.height))
        moodTabButton.frame = tabRects[Tab.mood.rawValue]
        soundTabButton.frame = tabRects[Tab.sound.rawValue]

        if let fanView = embeddedFanControlView {
            fanView.frame.size = NSSize(
                width: bounds.width,
                height: max(viewportHeight, fanView.minimumContentHeight)
            )
        }
        if let soundView = embeddedSoundControlView {
            soundView.frame.size = NSSize(
                width: bounds.width,
                height: max(viewportHeight, soundView.minimumContentHeight)
            )
        }
    }

    func installFanControlView(_ view: FanControlView) {
        embeddedFanScrollView?.removeFromSuperview()
        embeddedFanControlView?.removeFromSuperview()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: Self.tabBarHeight, width: bounds.width, height: bounds.height - Self.tabBarHeight)
        )
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.isHidden = selectedTab != .fans
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(view.frame.height, FanControlView.preferredSize.height)
        )
        view.autoresizingMask = [.width]
        view.isHidden = selectedTab != .fans
        scrollView.documentView = view
        addSubview(scrollView)
        view.onContentHeightChange = { [weak self] in self?.needsLayout = true }
        embeddedFanControlView = view
        embeddedFanScrollView = scrollView
        addSubview(resizeHandle, positioned: .above, relativeTo: nil)
        needsLayout = true
    }

    func installSoundControlView(_ view: SoundControlView) {
        embeddedSoundScrollView?.removeFromSuperview()
        embeddedSoundControlView?.removeFromSuperview()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: Self.tabBarHeight, width: bounds.width, height: bounds.height - Self.tabBarHeight)
        )
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.isHidden = selectedTab != .sound
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: max(view.frame.height, SoundControlView.preferredSize.height)
        )
        view.autoresizingMask = [.width]
        view.isHidden = selectedTab != .sound
        scrollView.documentView = view
        addSubview(scrollView)
        view.onContentHeightChange = { [weak self] in self?.needsLayout = true }
        embeddedSoundControlView = view
        embeddedSoundScrollView = scrollView
        soundTabButton.isBordered = false
        soundTabButton.target = self
        soundTabButton.action = #selector(selectSoundTab)
        soundTabButton.setAccessibilityLabel("Sound tab")
        soundTabButton.toolTip = "App audio and Bluetooth typing feedback"
        addSubview(soundTabButton)
        addSubview(resizeHandle, positioned: .above, relativeTo: nil)
        needsLayout = true
    }

    func showLoading() {
        snapshot = nil
        updateEnergyAppButtons()
        statusMessage = "Collecting system metrics…"
        needsDisplay = true
    }

    func installMoodCompassView(_ view: MoodCompassView) {
        embeddedMoodScrollView?.removeFromSuperview()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: Self.tabBarHeight, width: bounds.width, height: bounds.height - Self.tabBarHeight))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.autoresizingMask = [.width, .height]
        scroll.isHidden = selectedTab != .mood
        view.frame.size = MoodCompassView.preferredSize
        view.autoresizingMask = [.width]; scroll.documentView = view
        addSubview(scroll)
        embeddedMoodScrollView = scroll; embeddedMoodView = view
        moodTabButton.isBordered = false
        moodTabButton.target = self; moodTabButton.action = #selector(selectMoodTab)
        moodTabButton.setAccessibilityLabel("Mood Compass tab")
        moodTabButton.toolTip = "Mood Compass · experimental, local estimates"
        addSubview(moodTabButton)
        addSubview(resizeHandle, positioned: .above, relativeTo: nil)
        needsLayout = true
    }

    @objc private func selectMoodTab() { selectTab(at: Tab.mood.rawValue) }
    @objc private func selectSoundTab() { selectTab(at: Tab.sound.rawValue) }

    func showError(_ message: String) {
        snapshot = nil
        updateEnergyAppButtons()
        statusMessage = "Unable to read system metrics\n\(message)"
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTabBar()
        if showsHistoryRange {
            drawHistoryRangeBar()
        }
        if selectedTab == .fans || selectedTab == .sound || selectedTab == .mood || isPetPageSelected { return }
        guard let snapshot else {
            drawStatusMessage()
            return
        }

        switch selectedTab {
        case .system:
            NSGraphicsContext.saveGraphicsState()
            let translation = NSAffineTransform()
            translation.translateX(by: 0, yBy: Self.systemPageOffset)
            translation.concat()
            if systemPage == .overview {
                drawChipAndMemory(snapshot)
                drawSeparator(y: Self.batteryOriginY - 5)
                drawBattery(snapshot.batteryMetrics, topApps: snapshot.topApps, originY: Self.batteryOriginY)
            } else { drawInsights(snapshot) }
            NSGraphicsContext.restoreGraphicsState()
        case .networkAndApps:
            drawNetworkAndApps(snapshot)
        case .sound, .fans, .mood:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInsightsTabSelected, point.y >= 160 + Self.systemPageOffset, point.y < 217 + Self.systemPageOffset {
            let index = Int((point.y - 160 - Self.systemPageOffset) / 19)
            if index < min(3, incidents.count) {
                replayPanel?.close()
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 240),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                panel.title = incidents[index].kind.rawValue + " · Replay"
                panel.isReleasedWhenClosed = false
                panel.contentView = IncidentReplayView(incident: incidents[index])
                panel.center()
                replayPanel = panel
                onOpenReplay?()
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
        if tabBarRect.contains(point) {
            let index = tabRects.firstIndex(where: { $0.contains(point) }) ?? Tab.allCases.count - 1
            selectTab(at: index)
            return
        }

        if showsHistoryRange, historyRangeBarRect.contains(point) {
            let rangeWidth = historyRangeBarRect.width / CGFloat(MetricHistoryRange.allCases.count)
            let index = min(
                MetricHistoryRange.allCases.count - 1,
                max(0, Int((point.x - historyRangeBarRect.minX) / rangeWidth))
            )
            selectHistoryRange(at: index)
            return
        }

        super.mouseDown(with: event)
    }

    func selectTab(at index: Int) {
        guard let tab = Tab(rawValue: index) else { return }
        selectedTab = tab
        updateEnergyAppButtons()
        embeddedFanControlView?.isHidden = tab != .fans
        embeddedFanScrollView?.isHidden = tab != .fans
        embeddedSoundControlView?.isHidden = tab != .sound
        embeddedSoundScrollView?.isHidden = tab != .sound
        embeddedMoodScrollView?.isHidden = tab != .mood
        embeddedPetView?.isHidden = !isPetPageSelected
        embeddedPetView?.setPageVisible(menuVisible && isPetPageSelected)
        diagnosticButton.isHidden = !isInsightsTabSelected
        systemPageControl.isHidden = tab != .system
        resizeHandle.isHidden = tab != .sound && tab != .fans && tab != .mood
        let targetHeight: CGFloat = switch tab {
        case .system: systemPage == .overview ? Self.systemSectionHeight : systemPage == .pet ? 62 + PetControlView.preferredHeight : Self.preferredSize.height + Self.systemPageOffset
        case .sound: soundHeight
        case .fans: fanHeight
        case .mood: moodHeight
        default: Self.preferredSize.height
        }
        applyHeight(targetHeight)
        if let snapshot {
            let section = tab == .system ? "System · \(["Overview", "Insights", "Pet"][systemPage.rawValue])" : tab.title.replacingOccurrences(of: "\n", with: " ")
            setAccessibilityValue("\(section) tab. \(accessibilitySummary(snapshot))")
        }
        needsDisplay = true
        onSectionChange?()
    }

    func resizeSelectedSection(to proposedHeight: CGFloat) {
        guard selectedTab == .sound || selectedTab == .fans || selectedTab == .mood else { return }
        let availableHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? Self.maximumResizableHeight
        let maximumHeight = max(
            Self.preferredSize.height,
            min(Self.maximumResizableHeight, availableHeight - 120)
        )
        let height = min(maximumHeight, max(Self.preferredSize.height, proposedHeight))
        if selectedTab == .sound {
            soundHeight = height
        } else if selectedTab == .fans {
            fanHeight = height
        } else {
            moodHeight = height
        }
        applyHeight(height)
    }

    private func applyHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else {
            needsLayout = true
            return
        }
        frame.size.height = height
        needsLayout = true
        layoutSubtreeIfNeeded()
        onHeightChange?()
    }

    func selectHistoryRange(at index: Int) {
        guard let range = MetricHistoryRange(rawValue: index) else { return }
        selectedHistoryRange = range
        if let snapshot {
            setAccessibilityValue("\(range.title) history. \(accessibilitySummary(snapshot))")
        }
        onHistoryRangeChange?(range)
        needsDisplay = true
    }

    private var tabBarRect: NSRect {
        NSRect(x: 10, y: 5, width: bounds.width - 20, height: 27)
    }

    private var tabRects: [NSRect] {
        var x = tabBarRect.minX
        let total = Self.tabWidthWeights.reduce(0, +)
        return Self.tabWidthWeights.map { weight in
            let width = tabBarRect.width * weight / total
            defer { x += width }
            return NSRect(x: x, y: tabBarRect.minY, width: width, height: tabBarRect.height)
        }
    }

    private var historyRangeBarRect: NSRect {
        NSRect(x: 66, y: 36 + (selectedTab == .system ? Self.systemPageOffset : 0), width: bounds.width - 82, height: 20)
    }

    private var showsHistoryRange: Bool {
        switch selectedTab {
        case .system: systemPage == .overview
        case .networkAndApps: true
        case .sound, .fans, .mood: false
        }
    }

    private func drawTabBar() {
        let outerPath = NSBezierPath(roundedRect: tabBarRect, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        outerPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        outerPath.lineWidth = 0.7
        outerPath.stroke()

        let rects = tabRects
        if tabHoverOpacity > 0.01 {
            let position = min(CGFloat(rects.count - 1), max(0, tabHoverPosition))
            let lower = Int(position), upper = min(rects.count - 1, lower + 1)
            let fraction = position - CGFloat(lower)
            let interpolatedX = rects[lower].minX + (rects[upper].minX - rects[lower].minX) * fraction
            let interpolatedWidth = rects[lower].width + (rects[upper].width - rects[lower].width) * fraction
            let hoverRect = NSRect(
                x: interpolatedX + 2,
                y: tabBarRect.minY + 2,
                width: interpolatedWidth - 4,
                height: tabBarRect.height - 4
            )
            NSColor.controlAccentColor.withAlphaComponent(0.10 * tabHoverOpacity).setFill()
            NSBezierPath(roundedRect: hoverRect, xRadius: 6, yRadius: 6).fill()
        }

        for tab in Tab.allCases {
            let tabRect = rects[tab.rawValue]

            if tab == selectedTab {
                let selectedRect = tabRect.insetBy(dx: 2, dy: 2)
                let selectedPath = NSBezierPath(roundedRect: selectedRect, xRadius: 6, yRadius: 6)
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14).setFill()
                selectedPath.fill()

                let indicator = NSBezierPath(
                    roundedRect: NSRect(x: selectedRect.minX + 8, y: selectedRect.maxY - 2, width: selectedRect.width - 16, height: 2),
                    xRadius: 1,
                    yRadius: 1
                )
                NSColor.controlAccentColor.setFill()
                indicator.fill()
            }

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            NSAttributedString(
                string: tab.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: tab.titleFontSize, weight: tab == selectedTab ? .semibold : .regular),
                    .foregroundColor: tab == selectedTab ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ]
            ).draw(in: NSRect(x: tabRect.minX + 3, y: tabRect.minY + (tab == .mood ? 3 : 6), width: tabRect.width - 6, height: tab == .mood ? 22 : 16))
        }
    }

    private func drawHistoryRangeBar() {
        let width = historyRangeBarRect.width / CGFloat(MetricHistoryRange.allCases.count)
        if rangeHoverOpacity > 0.01 {
            let hoverRect = NSRect(
                x: historyRangeBarRect.minX + rangeHoverPosition * width + 2,
                y: historyRangeBarRect.minY + 1,
                width: width - 4,
                height: historyRangeBarRect.height - 2
            )
            NSColor.controlAccentColor.withAlphaComponent(0.10 * rangeHoverOpacity).setFill()
            NSBezierPath(roundedRect: hoverRect, xRadius: 5, yRadius: 5).fill()
        }

        for range in MetricHistoryRange.allCases {
            let rect = NSRect(
                x: historyRangeBarRect.minX + CGFloat(range.rawValue) * width,
                y: historyRangeBarRect.minY,
                width: width,
                height: historyRangeBarRect.height
            )
            if range == selectedHistoryRange {
                let selected = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5)
                NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
                selected.fill()
            }

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            NSAttributedString(
                string: range.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9.2, weight: range == selectedHistoryRange ? .semibold : .regular),
                    .foregroundColor: range == selectedHistoryRange ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                    .paragraphStyle: style,
                ]
            ).draw(in: NSRect(x: rect.minX, y: rect.minY + 4, width: rect.width, height: 13))
        }
    }

    private func updateHover(at point: NSPoint) {
        if tabBarRect.contains(point) {
            let index = tabRects.firstIndex(where: { $0.contains(point) }) ?? Tab.allCases.count - 1
            if tabHoverOpacity < 0.01 { tabHoverPosition = CGFloat(index) }
            tabHoverTarget = CGFloat(index)
            tabHoverTargetOpacity = 1
        } else {
            tabHoverTargetOpacity = 0
        }

        if showsHistoryRange, historyRangeBarRect.contains(point) {
            let width = historyRangeBarRect.width / CGFloat(MetricHistoryRange.allCases.count)
            let index = min(
                MetricHistoryRange.allCases.count - 1,
                max(0, Int((point.x - historyRangeBarRect.minX) / width))
            )
            if rangeHoverOpacity < 0.01 { rangeHoverPosition = CGFloat(index) }
            rangeHoverTarget = CGFloat(index)
            rangeHoverTargetOpacity = 1
        } else {
            rangeHoverTargetOpacity = 0
        }
        startHoverAnimationIfNeeded()
    }

    private func clearHover() {
        tabHoverTargetOpacity = 0
        rangeHoverTargetOpacity = 0
        startHoverAnimationIfNeeded()
    }

    private func startHoverAnimationIfNeeded() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hoverAnimationTimer?.invalidate(); hoverAnimationTimer = nil
            tabHoverPosition = tabHoverTarget; tabHoverOpacity = tabHoverTargetOpacity
            rangeHoverPosition = rangeHoverTarget; rangeHoverOpacity = rangeHoverTargetOpacity
            needsDisplay = true
            return
        }
        guard hoverAnimationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let easing: CGFloat = 0.26
            self.tabHoverPosition += (self.tabHoverTarget - self.tabHoverPosition) * easing
            self.tabHoverOpacity += (self.tabHoverTargetOpacity - self.tabHoverOpacity) * easing
            self.rangeHoverPosition += (self.rangeHoverTarget - self.rangeHoverPosition) * easing
            self.rangeHoverOpacity += (self.rangeHoverTargetOpacity - self.rangeHoverOpacity) * easing
            self.needsDisplay = true

            let settled = abs(self.tabHoverPosition - self.tabHoverTarget) < 0.01
                && abs(self.tabHoverOpacity - self.tabHoverTargetOpacity) < 0.01
                && abs(self.rangeHoverPosition - self.rangeHoverTarget) < 0.01
                && abs(self.rangeHoverOpacity - self.rangeHoverTargetOpacity) < 0.01
            if settled {
                self.tabHoverPosition = self.tabHoverTarget
                self.tabHoverOpacity = self.tabHoverTargetOpacity
                self.rangeHoverPosition = self.rangeHoverTarget
                self.rangeHoverOpacity = self.rangeHoverTargetOpacity
                self.hoverAnimationTimer = nil
                timer.invalidate()
            }
        }
        timer.tolerance = 0.003
        RunLoop.main.add(timer, forMode: .common)
        hoverAnimationTimer = timer
    }

    private func drawChipAndMemory(_ snapshot: HardwareSnapshot) {
        let textRect = { (y: CGFloat, height: CGFloat) in
            NSRect(x: 60, y: y, width: 164, height: height)
        }
        let chartRect = { (y: CGFloat) in
            NSRect(x: 228, y: y, width: 116, height: 29)
        }

        drawSymbol("cpu", y: 65)
        drawCenteredText(
            "CPU \(percent(snapshot.cpuUsage)) · \(watts(snapshot.powerMetrics?.cpuWatts))",
            in: textRect(63, 16),
            font: .systemFont(ofSize: 11.2, weight: .semibold),
            color: .labelColor
        )
        let cpuDetail = snapshot.cpuBreakdown.map {
            "Sys \(percent($0.system)) · User \(percent($0.user)) · Idle \(percent($0.idle))"
        } ?? "Collecting CPU sample…"
        drawCenteredText(cpuDetail, in: textRect(79, 14), font: .systemFont(ofSize: 8.4), color: .secondaryLabelColor)
        drawHistoricalChart(
            in: chartRect(63),
            series: [
                ChartSeries(metric: .cpuUsage, title: "Load", color: .systemBlue, scale: .fraction),
                ChartSeries(metric: .cpuWatts, title: "Power", color: .systemOrange, scale: .ownMaximum),
            ],
            showsLegend: false
        )
        drawSeparator(y: 100)

        drawSymbol("rectangle.3.group", y: 108)
        drawCenteredText(
            "GPU \(percent(snapshot.gpuMetrics?.usage)) · \(watts(snapshot.powerMetrics?.gpuWatts))",
            in: textRect(105, 16),
            font: .systemFont(ofSize: 11.2, weight: .semibold),
            color: .labelColor
        )
        let gpuDetail = snapshot.gpuMetrics.map {
            "Renderer \(percent($0.rendererUsage)) · Tiler \(percent($0.tilerUsage))"
        } ?? "GPU utilization unavailable"
        drawCenteredText(gpuDetail, in: textRect(121, 14), font: .systemFont(ofSize: 8.7), color: .secondaryLabelColor)
        drawHistoricalChart(
            in: chartRect(106),
            series: [
                ChartSeries(metric: .gpuUsage, title: "Load", color: .systemGreen, scale: .fraction),
                ChartSeries(metric: .gpuWatts, title: "Power", color: .systemOrange, scale: .ownMaximum),
            ],
            showsLegend: false
        )
        drawSeparator(y: 141)

        drawSymbol("memorychip", y: 148)
        let leak = snapshot.memoryLeakAssessment == nil ? "" : " · Leak warning"
        drawCenteredText(
            "Memory \(percent(snapshot.memoryUsage)) · \(snapshot.memoryPressure.displayName)\(leak)",
            in: textRect(142, 16),
            font: .systemFont(ofSize: 10.8, weight: .semibold),
            color: snapshot.memoryLeakAssessment == nil ? .labelColor : .systemRed
        )
        if let memory = snapshot.memoryMetrics {
            drawCenteredText(
                "App \(bytes(memory.appBytes)) · Wired \(bytes(memory.wiredBytes))",
                in: textRect(158, 13),
                font: .systemFont(ofSize: 8.4),
                color: .secondaryLabelColor
            )
            drawCenteredText(
                "Compressed \(bytes(memory.compressedBytes))",
                in: textRect(170, 12),
                font: .systemFont(ofSize: 8.2),
                color: .tertiaryLabelColor
            )
        }
        drawHistoricalChart(
            in: chartRect(147),
            series: [ChartSeries(metric: .memoryUsage, title: "Memory", color: .systemPurple, scale: .fraction)],
            showsLegend: false
        )
        drawSeparator(y: 182)

        drawSymbol("internaldrive", y: 190)
        if let storage = snapshot.storageMetrics {
            drawCenteredText(
                "Storage \(percent(storage.usage)) used",
                in: textRect(188, 16),
                font: .systemFont(ofSize: 11.0, weight: .semibold),
                color: .labelColor
            )
            drawCenteredText(
                "\(storageBytes(storage.usedBytes)) / \(storageBytes(storage.totalBytes))",
                in: textRect(204, 14),
                font: .systemFont(ofSize: 8.7),
                color: .secondaryLabelColor
            )
        } else {
            drawCenteredText("Storage unavailable", in: textRect(195, 16), font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor)
        }
        drawHistoricalChart(
            in: chartRect(188),
            series: [ChartSeries(metric: .storageUsage, title: "Used", color: .systemBlue, scale: .adaptive)],
            showsLegend: false
        )
    }

    private func drawNetworkAndApps(_ snapshot: HardwareSnapshot) {
        drawSymbol("network", y: 76)
        if let network = snapshot.networkMetrics {
            drawText(
                "Network · \(network.displayName)",
                in: NSRect(x: 60, y: 60, width: 164, height: 16),
                font: .systemFont(ofSize: 11.2, weight: .semibold),
                color: .labelColor
            )
            drawText("IP \(network.localIPAddress)", in: NSRect(x: 60, y: 77, width: 164, height: 13), font: .systemFont(ofSize: 8.6), color: .secondaryLabelColor)
            drawText("↑ \(speed(network.uploadBytesPerSecond)) · ↓ \(speed(network.downloadBytesPerSecond))", in: NSRect(x: 60, y: 91, width: 164, height: 13), font: .systemFont(ofSize: 8.4), color: .secondaryLabelColor)
            drawText("Signal \(signal(network.signalRSSI)) · Ping \(latency(network.latencyMilliseconds))", in: NSRect(x: 60, y: 105, width: 164, height: 13), font: .systemFont(ofSize: 8.4), color: .secondaryLabelColor)
            drawText("\(transmitRate(network.transmitRateMbps)) · \(network.interfaceName)", in: NSRect(x: 60, y: 119, width: 164, height: 13), font: .systemFont(ofSize: 8.2), color: .tertiaryLabelColor)
        } else {
            drawText("Network unavailable", in: NSRect(x: 60, y: 67, width: 164, height: 16), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        drawHistoricalChart(
            in: NSRect(x: 228, y: 63, width: 116, height: 66),
            series: [
                ChartSeries(metric: .networkDownload, title: "Down", color: .systemBlue, scale: .sharedMaximum([.networkDownload, .networkUpload])),
                ChartSeries(metric: .networkUpload, title: "Up", color: .systemGreen, scale: .sharedMaximum([.networkDownload, .networkUpload])),
                ChartSeries(metric: .networkLatency, title: "Ping", color: .systemOrange, scale: .ownMaximum),
            ],
            showsLegend: false
        )
        drawSeparator(y: 137)

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.midX, y: 145))
        divider.line(to: NSPoint(x: bounds.midX, y: 220))
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        divider.lineWidth = 0.5
        divider.stroke()

        drawCompactAppColumn(
            title: "Highest Load",
            apps: Array(snapshot.topApps.prefix(3)),
            x: 18
        )
        drawCompactAppColumn(
            title: "Background Load",
            apps: Array(snapshot.topApps.filter(\.isBackground).prefix(3)),
            x: bounds.midX + 8
        )
    }

    private func drawInsights(_ snapshot: HardwareSnapshot) {
        let top = Self.contentOriginY - 14
        drawSymbol("waveform.path.ecg", y: top + 2)
        drawText(
            thermalPrediction?.summary ?? "Collecting thermal trend…",
            in: NSRect(x: 60, y: top, width: 254, height: 17),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .labelColor
        )
        let trend = thermalPrediction.map {
            String(format: "Trend %+.1f°C/min · %.0f°C now · %@ mode", $0.slopePerMinute, $0.temperature, monitoringMode.rawValue)
        } ?? "Prediction needs several live samples"
        drawText(trend, in: NSRect(x: 60, y: top + 18, width: 254, height: 14), font: .systemFont(ofSize: 8.5), color: .secondaryLabelColor)

        drawSeparator(y: 86)
        let normalText = personalRange.map {
            String(format: "%@ · Typical %.0f–%.0f°C", $0.context, $0.low, $0.high)
        } ?? "Personal normal · Learning (20 samples per context)"
        drawText(normalText, in: NSRect(x: 18, y: 94, width: 322, height: 15),
                 font: .systemFont(ofSize: 9.2, weight: .medium), color: .secondaryLabelColor)
        let normalDetails = personalRange.map { range in
            let watts = range.watts.map { String(format: "%.1f–%.1f W", $0.lowerBound, $0.upperBound) } ?? "Power learning"
            let fans = range.rpm.map { String(format: "%.0f–%.0f RPM", $0.lowerBound, $0.upperBound) } ?? "Fans learning"
            return "\(watts) · \(fans) · Local baseline"
        } ?? "Baseline learns temperature, chip power, and fan RPM"
        drawText(normalDetails, in: NSRect(x: 18, y: 109, width: 322, height: 13),
                 font: .systemFont(ofSize: 8.2), color: .secondaryLabelColor)
        let gauge = NSRect(x: 18, y: 128, width: 322, height: 4)
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: gauge, xRadius: 3, yRadius: 3).fill()
        if let range = personalRange {
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: gauge.minX + CGFloat(range.low / 120) * gauge.width,
                y: gauge.minY, width: max(3, CGFloat((range.high - range.low) / 120) * gauge.width), height: 4),
                         xRadius: 3, yRadius: 3).fill()
        }
        if let temperature = snapshot.chipTemperature {
            NSColor.labelColor.setFill()
            NSRect(x: gauge.minX + CGFloat(min(120, max(0, temperature)) / 120) * gauge.width,
                   y: gauge.minY - 2, width: 2, height: 10).fill()
        }
        drawText(
            "INCIDENTS · CLICK TO REPLAY",
            in: NSRect(x: 18, y: 140, width: 280, height: 14),
            font: .systemFont(ofSize: 8.5, weight: .semibold),
            color: .secondaryLabelColor
        )
        if incidents.isEmpty {
            drawText(
                "No sustained incidents recorded",
                in: NSRect(x: 18, y: 165, width: 320, height: 18),
                font: .systemFont(ofSize: 10),
                color: .tertiaryLabelColor
            )
        } else {
            for (index, incident) in incidents.prefix(3).enumerated() {
                let y = 160 + CGFloat(index) * 19
                let status = incident.endedAt == nil ? "LIVE" : Self.incidentTimeFormatter.string(from: incident.startedAt)
                drawText(
                    "\(incident.kind.rawValue) · \(incident.peakSummary)",
                    in: NSRect(x: 20, y: y, width: 252, height: 16),
                    font: .systemFont(ofSize: 9.2, weight: incident.endedAt == nil ? .semibold : .regular),
                    color: incident.endedAt == nil ? .systemOrange : .labelColor
                )
                drawRightAlignedText(status, in: NSRect(x: 274, y: y, width: 65, height: 16), fontSize: 8.2)
            }
        }
    }

    @objc private func exportDiagnostics() {
        onExportDiagnostics?()
    }

    private func drawCompactAppColumn(title: String, apps: [TopAppMetrics], x: CGFloat) {
        let width = bounds.midX - 26
        drawText(
            title,
            in: NSRect(x: x, y: 141, width: width, height: 16),
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: .labelColor
        )
        guard !apps.isEmpty else {
            drawText(
                title == "Background Load" ? "No notable background load" : "Collecting activity…",
                in: NSRect(x: x, y: 160, width: width, height: 14),
                font: .systemFont(ofSize: 9.2),
                color: .secondaryLabelColor
            )
            return
        }

        for (index, app) in apps.enumerated() {
            let y = 157 + CGFloat(index * 22)
            drawText(
                "\(index + 1). \(app.name)",
                in: NSRect(x: x, y: y, width: width, height: 14),
                font: .systemFont(ofSize: 9.8, weight: .semibold),
                color: .labelColor,
                lineBreakMode: .byTruncatingTail
            )
            drawText(
                String(format: "%.1f%% · %@ · E %.1f", app.cpuPercent, bytes(app.memoryBytes), app.energyImpact),
                in: NSRect(x: x + 11, y: y + 12, width: width - 11, height: 11),
                font: .monospacedDigitSystemFont(ofSize: 8.3, weight: .regular),
                color: .secondaryLabelColor
            )
        }
    }

    private func drawGPU(_ snapshot: HardwareSnapshot, originY: CGFloat) {
        drawSymbol("rectangle.3.group", y: originY + 23)
        drawTitle(
            "GPU: \(percent(snapshot.gpuMetrics?.usage))    Power: \(watts(snapshot.powerMetrics?.gpuWatts))",
            y: originY + 7
        )
        if let gpu = snapshot.gpuMetrics {
            drawDetail(
                "Renderer: \(percent(gpu.rendererUsage))    Tiler: \(percent(gpu.tilerUsage))",
                y: originY + 28
            )
        } else {
            drawDetail("GPU utilization unavailable", y: originY + 28)
        }
        drawHistoricalChart(
            in: NSRect(x: 66, y: originY + 47, width: 278, height: 25),
            series: [
                ChartSeries(metric: .gpuUsage, title: "Load", color: .systemGreen, scale: .fraction),
                ChartSeries(metric: .gpuWatts, title: "Power", color: .systemOrange, scale: .ownMaximum),
            ]
        )
    }

    private func drawCPU(_ snapshot: HardwareSnapshot, originY: CGFloat) {
        drawSymbol("cpu", y: originY + 27)
        drawTitle(
            "CPU: \(percent(snapshot.cpuUsage))    Power: \(watts(snapshot.powerMetrics?.cpuWatts))",
            y: originY + 8
        )

        if let cpu = snapshot.cpuBreakdown {
            drawDetail(
                "System: \(percent(cpu.system))    User: \(percent(cpu.user))    Idle: \(percent(cpu.idle))",
                y: originY + 30
            )
        } else {
            drawDetail("Collecting first CPU sample…", y: originY + 30)
        }
        drawHistoricalChart(
            in: NSRect(x: 66, y: originY + 50, width: 278, height: 25),
            series: [
                ChartSeries(metric: .cpuUsage, title: "Load", color: .systemBlue, scale: .fraction),
                ChartSeries(metric: .cpuWatts, title: "Power", color: .systemOrange, scale: .ownMaximum),
            ]
        )
    }

    private func drawMemory(_ snapshot: HardwareSnapshot, originY: CGFloat) {
        drawSymbol("memorychip", y: originY + 35)
        drawTitle("Memory: \(percent(snapshot.memoryUsage))", y: originY + 8)
        let leakStatus = snapshot.memoryLeakAssessment.map {
            String(format: "    Leak? +%.1f GB", Double($0.growthBytes) / 1_000_000_000)
        } ?? ""
        drawDetail("Pressure: \(snapshot.memoryPressure.displayName)\(leakStatus)", y: originY + 29)

        if let memory = snapshot.memoryMetrics {
            drawDetail(
                "App: \(bytes(memory.appBytes))    Wired: \(bytes(memory.wiredBytes))",
                y: originY + 47,
                fontSize: 9.8
            )
            drawDetail("Compressed: \(bytes(memory.compressedBytes))", y: originY + 61, fontSize: 9.8)
        } else {
            drawDetail("Memory details unavailable", y: originY + 47)
        }
        drawHistoricalChart(
            in: NSRect(x: 66, y: originY + 78, width: 278, height: 16),
            series: [ChartSeries(metric: .memoryUsage, title: "Memory", color: .systemPurple, scale: .fraction)],
            showsLegend: false
        )
    }

    private func drawStorage(_ storage: StorageMetrics?, originY: CGFloat) {
        drawSymbol("internaldrive", y: originY + 19)
        guard let storage else {
            drawTitle("Storage: Unavailable", y: originY + 9)
            return
        }

        drawTitle("Storage: \(percent(storage.usage)) used", y: originY + 6)
        drawDetail("\(storageBytes(storage.usedBytes)) / \(storageBytes(storage.totalBytes))", y: originY + 28)

        drawHistoricalChart(
            in: NSRect(x: 66, y: originY + 46, width: 278, height: 17),
            series: [ChartSeries(metric: .storageUsage, title: "Used", color: .systemBlue, scale: .adaptive)],
            showsLegend: false
        )
    }

    private func drawBattery(_ battery: BatteryMetrics?, topApps: [TopAppMetrics], originY: CGFloat) {
        drawSymbol("battery.100percent", y: originY + 27)
        guard let battery else {
            drawTitle("Battery: Unavailable", y: originY + 8)
            return
        }

        let power = battery.powerWatts.map { String(format: "%.1f W", $0) } ?? "Unavailable"
        drawTitle("Battery: \(percent(battery.level))    Power: \(power)", y: originY + 6)

        let temperature = battery.temperature.map { String(format: "%.1f°C", $0) } ?? "—"
        let state: String
        if battery.isCharging {
            state = "Charging"
        } else if battery.powerSource == "Power Adapter" {
            state = "On AC"
        } else {
            state = "ETA \(duration(battery.estimatedMinutesRemaining)) · \(battery.estimateConfidence == .adaptive ? "Adaptive" : "Learning")"
        }
        drawDetail("\(state)    Temperature: \(temperature)", y: originY + 27, fontSize: 9.8)
        let energy = battery.remainingEnergyWh.map { String(format: "%.1f Wh remaining", $0) } ?? "Energy unavailable"
        let health = battery.maximumCapacity.map { String(format: "%.0f%% health", $0 * 100) } ?? "Health unavailable"
        drawDetail("\(energy)    \(health)", y: originY + 44, color: .tertiaryLabelColor, fontSize: 9.5)
        drawHistoricalChart(
            in: NSRect(x: 66, y: originY + 66, width: 156, height: 82),
            series: [
                ChartSeries(metric: .batteryLevel, title: "Level", color: .systemGreen, scale: .fraction),
                ChartSeries(metric: .batteryWatts, title: "Power", color: .systemOrange, scale: .ownMaximum),
            ]
        )

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 229, y: originY + 68))
        divider.line(to: NSPoint(x: 229, y: originY + 146))
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        divider.lineWidth = 0.5
        divider.stroke()
        drawBatteryConsumers(Self.topEnergyApps(from: topApps), originY: originY)
    }

    static func topEnergyApps(from apps: [TopAppMetrics], limit: Int = 3) -> [TopAppMetrics] {
        Array(
            apps
                .filter { $0.energyImpact.isFinite && $0.energyImpact > 0 }
                .sorted {
                    if $0.energyImpact != $1.energyImpact { return $0.energyImpact > $1.energyImpact }
                    if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                .prefix(max(0, limit))
        )
    }

    private func drawBatteryConsumers(_ apps: [TopAppMetrics], originY: CGFloat) {
        let x: CGFloat = 237
        let width: CGFloat = 107
        drawText(
            "TOP ENERGY APPS",
            in: NSRect(x: x, y: originY + 66, width: width, height: 13),
            font: .systemFont(ofSize: 8.4, weight: .semibold),
            color: .secondaryLabelColor
        )
        guard !apps.isEmpty else {
            drawText(
                "Collecting energy use…",
                in: NSRect(x: x, y: originY + 86, width: width, height: 24),
                font: .systemFont(ofSize: 7.8),
                color: .tertiaryLabelColor
            )
            return
        }

        for (index, app) in apps.enumerated() {
            let y = originY + 82 + CGFloat(index * 22)
            drawText(
                "\(index + 1). \(app.name)",
                in: NSRect(x: x, y: y, width: width, height: 12),
                font: .systemFont(ofSize: 8.8, weight: .semibold),
                color: .labelColor,
                lineBreakMode: .byTruncatingTail
            )
            drawText(
                String(format: "Energy impact %.1f", app.energyImpact),
                in: NSRect(x: x + 10, y: y + 11, width: width - 10, height: 11),
                font: .monospacedDigitSystemFont(ofSize: 7.5, weight: .regular),
                color: .secondaryLabelColor
            )
        }
    }

    private func drawNetwork(_ network: NetworkMetrics?, originY: CGFloat) {
        drawSymbol("network", y: originY + 31)
        guard let network else {
            drawTitle("Network: Unavailable", y: originY + 9)
            return
        }

        drawTitle("Network: \(network.displayName)", y: originY + 7)
        drawDetail("Local IP: \(network.localIPAddress)", y: originY + 28)
        drawDetail(
            "Upload: \(speed(network.uploadBytesPerSecond))    Download: \(speed(network.downloadBytesPerSecond))",
            y: originY + 43
        )
        drawDetail(
            "Signal: \(signal(network.signalRSSI))    Latency: \(latency(network.latencyMilliseconds))",
            y: originY + 59,
            fontSize: 9.8
        )
        drawDetail(
            "Tx Rate: \(transmitRate(network.transmitRateMbps))    Interface: \(network.interfaceName)",
            y: originY + 75,
            color: .tertiaryLabelColor,
            fontSize: 9.8
        )
        drawHistoricalChart(
            in: NSRect(x: 66, y: originY + 96, width: 278, height: 52),
            series: [
                ChartSeries(
                    metric: .networkDownload,
                    title: "Down",
                    color: .systemBlue,
                    scale: .sharedMaximum([.networkDownload, .networkUpload])
                ),
                ChartSeries(
                    metric: .networkUpload,
                    title: "Up",
                    color: .systemGreen,
                    scale: .sharedMaximum([.networkDownload, .networkUpload])
                ),
                ChartSeries(metric: .networkLatency, title: "Ping", color: .systemOrange, scale: .ownMaximum),
            ]
        )
    }

    private func drawTopApps(_ apps: [TopAppMetrics], originY: CGFloat) {
        drawSymbol("list.number", y: originY + 40)
        drawTitle("Top Resource-Consuming Apps", y: originY + 7)
        guard !apps.isEmpty else {
            drawDetail("Collecting process activity…", y: originY + 31)
            return
        }

        for (index, app) in apps.prefix(5).enumerated() {
            let y = originY + 29 + CGFloat(index * 15)
            drawText(
                "\(index + 1). \(app.name)",
                in: NSRect(x: 66, y: y, width: 152, height: 15),
                font: .systemFont(ofSize: 9.8),
                color: .secondaryLabelColor
            )
            drawRightAlignedText(
                String(format: "%.0f%% CPU · %@", app.cpuPercent, bytes(app.memoryBytes)),
                in: NSRect(x: 214, y: y, width: 130, height: 15),
                fontSize: 9.3
            )
        }
    }

    private func drawStatusMessage() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: statusMessage, attributes: attributes)
        let size = text.boundingRect(
            with: NSSize(width: bounds.width - 40, height: 100),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let contentMidY = Self.tabBarHeight + (bounds.height - Self.tabBarHeight) / 2
        text.draw(in: NSRect(x: 20, y: contentMidY - size.height / 2, width: bounds.width - 40, height: size.height))
    }

    private func drawTitle(_ string: String, y: CGFloat) {
        drawText(string, in: NSRect(x: 66, y: y, width: 278, height: 20), font: .systemFont(ofSize: 14, weight: .medium), color: .labelColor)
    }

    private func drawDetail(
        _ string: String,
        y: CGFloat,
        color: NSColor = .secondaryLabelColor,
        fontSize: CGFloat = 10.5
    ) {
        drawText(string, in: NSRect(x: 66, y: y, width: 278, height: 18), font: .systemFont(ofSize: fontSize), color: color)
    }

    private func drawText(
        _ string: String, in rect: NSRect, font: NSFont, color: NSColor,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lineBreakMode
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        ).draw(in: rect)
    }

    private func drawCenteredText(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        ).draw(in: rect)
    }

    private func drawRightAlignedText(_ string: String, in rect: NSRect, fontSize: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: style,
            ]
        ).draw(in: rect)
    }

    private func drawSymbol(_ name: String, y: CGFloat) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        ) else { return }
        image.draw(in: NSRect(x: 23, y: y, width: 26, height: 26))
    }

    private func drawSeparator(y: CGFloat) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 16, y: y))
        path.line(to: NSPoint(x: bounds.width - 16, y: y))
        path.lineWidth = 0.5
        path.stroke()
    }

    private enum ChartScale {
        case fraction
        case ownMaximum
        case sharedMaximum([HistoricalMetric])
        case adaptive
    }

    private struct ChartSeries {
        let metric: HistoricalMetric
        let title: String
        let color: NSColor
        let scale: ChartScale
    }

    private func drawHistoricalChart(
        in rect: NSRect,
        series: [ChartSeries],
        showsLegend: Bool = true
    ) {
        let legendHeight: CGFloat = showsLegend ? 10 : 0
        let plotRect = NSRect(
            x: rect.minX,
            y: rect.minY + legendHeight,
            width: rect.width,
            height: max(4, rect.height - legendHeight)
        )

        if showsLegend {
            var x = rect.minX
            for item in series {
                item.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY + 4, width: 8, height: 2), xRadius: 1, yRadius: 1).fill()
                drawText(
                    item.title,
                    in: NSRect(x: x + 11, y: rect.minY, width: 38, height: 10),
                    font: .systemFont(ofSize: 7.8, weight: .medium),
                    color: .tertiaryLabelColor
                )
                x += 49
            }
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plotRect).addClip()
        NSColor.separatorColor.withAlphaComponent(0.38).setStroke()
        for fraction in [CGFloat(0), 0.5, 1] {
            let y = plotRect.minY + plotRect.height * fraction
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: plotRect.minX, y: y))
            guide.line(to: NSPoint(x: plotRect.maxX, y: y))
            guide.lineWidth = 0.5
            guide.stroke()
        }

        let end = snapshot?.timestamp ?? history.last?.timestamp ?? Date()
        let start = selectedHistoryRange.startDate(relativeTo: end)
        let duration = max(1, end.timeIntervalSince(start))
        for item in series {
            let values = history.compactMap { point -> (Date, Double)? in
                guard let value = point[item.metric], value.isFinite else { return nil }
                return (point.timestamp, value)
            }
            guard !values.isEmpty else { continue }
            let domain = chartDomain(for: item.scale, values: values.map { $0.1 })
            let path = NSBezierPath()
            for (index, sample) in values.enumerated() {
                let elapsed = sample.0.timeIntervalSince(start)
                let xPosition = min(1, max(0, elapsed / duration))
                let normalized = min(1, max(0, (sample.1 - domain.minimum) / domain.span))
                let point = NSPoint(
                    x: plotRect.minX + CGFloat(xPosition) * plotRect.width,
                    y: plotRect.maxY - CGFloat(normalized) * plotRect.height
                )
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            item.color.setStroke()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()

            if values.count == 1 {
                let point = path.currentPoint
                item.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 1.75, y: point.y - 1.75, width: 3.5, height: 3.5)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func chartDomain(for scale: ChartScale, values: [Double]) -> (minimum: Double, span: Double) {
        switch scale {
        case .fraction:
            return (0, 1)
        case .ownMaximum:
            return (0, max(1, (values.max() ?? 0) * 1.08))
        case let .sharedMaximum(metrics):
            let maximum = history.flatMap { point in metrics.compactMap { point[$0] } }.max() ?? 0
            return (0, max(1, maximum * 1.08))
        case .adaptive:
            let minimum = values.min() ?? 0
            let maximum = values.max() ?? 1
            let padding = max(0.005, (maximum - minimum) * 0.12)
            let lower = max(0, minimum - padding)
            let upper = min(1, maximum + padding)
            return (lower, max(0.01, upper - lower))
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "Unavailable"
    }

    private func watts(_ value: Double?) -> String {
        value.map { String(format: "%.1f W", $0) } ?? "Unavailable"
    }

    private func duration(_ minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes >= 0 else { return "Learning…" }
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }

    private func bytes<T: BinaryInteger>(_ value: T) -> String {
        Self.byteFormatter.string(fromByteCount: Int64(value))
    }

    private func speed(_ value: Double?) -> String {
        guard let value else { return "Collecting…" }
        return Self.speedFormatter.string(fromByteCount: Int64(max(0, value))) + "/s"
    }

    private func storageBytes(_ value: Int64) -> String {
        Self.storageFormatter.string(fromByteCount: value)
    }

    private func signal(_ value: Int?) -> String {
        value.map { "\($0) dBm" } ?? "Unavailable"
    }

    private func latency(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded())) ms" } ?? "Collecting…"
    }

    private func transmitRate(_ value: Double?) -> String {
        value.map { String(format: "%.0f Mbps", $0) } ?? "Unavailable"
    }

    private func accessibilitySummary(_ snapshot: HardwareSnapshot) -> String {
        let cpu = "CPU \(percent(snapshot.cpuUsage))"
        let gpu = "GPU \(percent(snapshot.gpuMetrics?.usage))"
        let cpuPower = snapshot.powerMetrics?.cpuWatts.map { String(format: "CPU power %.1f watts", $0) }
        let gpuPower = snapshot.powerMetrics?.gpuWatts.map { String(format: "GPU power %.1f watts", $0) }
        let memory = "memory \(percent(snapshot.memoryUsage)), pressure \(snapshot.memoryPressure.displayName)"
        let memoryLeak = snapshot.memoryLeakAssessment.map {
            String(format: "possible memory leak, %.1f gigabytes growth", Double($0.growthBytes) / 1_000_000_000)
        }
        let storage = snapshot.storageMetrics.map { "storage \(percent($0.usage)) used" } ?? "storage unavailable"
        let battery = snapshot.batteryMetrics.map {
            let power = $0.powerWatts.map { String(format: ", %.1f watts", $0) } ?? ""
            let eta = $0.estimatedMinutesRemaining.map { ", approximately \(Int($0.rounded())) minutes remaining" } ?? ""
            let temperature = $0.temperature.map { String(format: "%.1f degrees Celsius", $0) } ?? "temperature unavailable"
            return "battery \(percent($0.level)), \(temperature)\(power)\(eta)"
        } ?? "battery unavailable"
        let network = snapshot.networkMetrics.map { "network \($0.displayName), local IP \($0.localIPAddress)" } ?? "network unavailable"
        let topApps = snapshot.topApps.map(\.name).joined(separator: ", ")
        let backgroundApps = snapshot.topApps.filter(\.isBackground).prefix(3).map(\.name).joined(separator: ", ")
        return [cpu, cpuPower, gpu, gpuPower, memory, memoryLeak, storage, battery, network, "top apps \(topApps)", "background load \(backgroundApps)"]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let speedFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let storageFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static let incidentTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private final class BottomResizeHandleView: NSView {
    var onResize: ((CGFloat) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var dragTimer: Timer?
    private var isHovered = false
    private var isDragging = false
    private var initialMouseY: CGFloat = 0
    private var initialHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag to show more or less content"
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize Sound, Fans or Mood Compass panel")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        dragTimer?.invalidate()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.resizeUpDown.set()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = isDragging
        if !isDragging {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        finishDragging()
        initialMouseY = NSEvent.mouseLocation.y
        initialHeight = superview?.frame.height ?? SystemDetailsView.preferredSize.height
        isDragging = true
        isHovered = true
        NSCursor.resizeUpDown.set()
        needsDisplay = true

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateDraggedHeight()
            if NSEvent.pressedMouseButtons & 1 == 0 {
                self.finishDragging()
            }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDraggedHeight()
    }

    override func mouseUp(with event: NSEvent) {
        updateDraggedHeight()
        finishDragging()
    }

    private func updateDraggedHeight() {
        guard isDragging else { return }
        NSCursor.resizeUpDown.set()
        let downwardDistance = initialMouseY - NSEvent.mouseLocation.y
        onResize?(initialHeight + downwardDistance)
    }

    private func finishDragging() {
        dragTimer?.invalidate()
        dragTimer = nil
        guard isDragging else { return }
        isDragging = false
        updateHoverFromCurrentPointer()
        needsDisplay = true
    }

    private func updateHoverFromCurrentPointer() {
        guard let window else {
            isHovered = false
            NSCursor.arrow.set()
            return
        }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        isHovered = bounds.contains(point)
        (isHovered ? NSCursor.resizeUpDown : NSCursor.arrow).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width: CGFloat = isHovered ? 54 : 38
        let grip = NSRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - 2) / 2,
            width: width,
            height: 2
        )
        let color = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.72)
            : NSColor.separatorColor.withAlphaComponent(0.72)
        color.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
    }
}
