import AppKit
import FanControlProtocol
import XCTest
@testable import ThermoBar

final class SystemDetailsViewTests: XCTestCase {
    @MainActor
    func testIncidentReplayRendersRecordedValues() throws {
        let start = Date()
        let points = (0..<61).map { index in
            IncidentMetricPoint(timestamp: start.addingTimeInterval(Double(index - 30)),
                temperature: 65 + Double(index) / 3, fanRPM: Double(index) * 80,
                cpuUsage: 0.6, gpuUsage: 0.3, memoryUsage: 0.5, batteryTemperature: 32,
                latencyMilliseconds: 12, appName: "Browser", chipWatts: Double(index) / 2)
        }
        let view = IncidentReplayView(incident: MonitoringIncident(id: UUID(), kind: .thermal,
            startedAt: start, endedAt: nil, points: points))
        view.appearance = NSAppearance(named: .aqua)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4000)
        if ProcessInfo.processInfo.environment["THERMOBAR_PREVIEW_PATH"] != nil {
            try data.write(to: URL(fileURLWithPath: "/private/tmp/thermobar-incident-replay.png"))
        }
    }

    func testBatteryConsumersAreRankedByEnergyImpact() {
        let ranked = SystemDetailsView.topEnergyApps(from: [
            TopAppMetrics(name: "Browser", cpuPercent: 20, memoryBytes: 1, energyImpact: 14),
            TopAppMetrics(name: "Game", cpuPercent: 12, memoryBytes: 1, energyImpact: 48),
            TopAppMetrics(name: "Idle", cpuPercent: 0, memoryBytes: 1, energyImpact: 0),
            TopAppMetrics(name: "Music", cpuPercent: 4, memoryBytes: 1, energyImpact: 9),
            TopAppMetrics(name: "Editor", cpuPercent: 8, memoryBytes: 1, energyImpact: 22),
        ])

        XCTAssertEqual(ranked.map(\.name), ["Game", "Editor", "Browser"])
    }

    @MainActor
    func testSoundAndFansRememberIndependentExpandedHeights() throws {
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        let sound = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        let fans = FanControlView(frame: NSRect(origin: .zero, size: FanControlView.preferredSize))
        details.installSoundControlView(sound)
        details.installFanControlView(fans)

        var heightChangeCount = 0
        details.onHeightChange = { heightChangeCount += 1 }

        details.selectTab(at: 2)
        details.resizeSelectedSection(to: 410)
        XCTAssertEqual(details.frame.height, 410)

        details.selectTab(at: 3)
        XCTAssertEqual(details.frame.height, SystemDetailsView.preferredSize.height)
        details.resizeSelectedSection(to: 520)
        XCTAssertEqual(details.frame.height, 520)

        details.selectTab(at: 2)
        XCTAssertEqual(details.frame.height, 410)
        details.layoutSubtreeIfNeeded()
        let soundScroll = try XCTUnwrap(details.subviews.compactMap { $0 as? NSScrollView }.first { $0.documentView === sound })
        XCTAssertEqual(soundScroll.frame.height, 410 - 36 - 14)
        XCTAssertGreaterThanOrEqual(sound.frame.height, soundScroll.frame.height)

        details.selectTab(at: 0)
        XCTAssertEqual(details.frame.height, SystemDetailsView.systemSectionHeight)
        details.selectTab(at: 3)
        XCTAssertEqual(details.frame.height, 520)
        XCTAssertGreaterThanOrEqual(heightChangeCount, 5)
    }

    @MainActor
    func testResizableTabsClampToCompactMinimum() {
        let details = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        details.selectTab(at: 2)
        details.resizeSelectedSection(to: 40)
        XCTAssertEqual(details.frame.height, SystemDetailsView.preferredSize.height)
    }

    @MainActor
    func testSoundShowsHardwareMuteInsteadOfClaimingAudiblePlayback() throws {
        let view = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        let app = SoundPlaybackApp(
            processObjectID: 116, pid: 100, displayPID: 100, name: "Music",
            bundleIdentifier: "com.apple.Music", kind: .music, volume: 1,
            selectedOutputUID: "speakers", routeState: .routed
        )
        view.update(SoundControlSnapshot(apps: [app], devices: [
            SoundOutputDevice(id: 78, uid: "speakers", name: "MacBook Pro Speakers", isDefault: true,
                              volume: 0.3125, isMuted: true),
        ]))
        let texts = allSubviews(in: view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(texts.contains("Muted"))
        XCTAssertTrue(texts.contains("MUTED"))
        XCTAssertTrue(texts.contains("Output muted · adjust device volume"))
        let output = try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Choose app audio output"))
        XCTAssertTrue(output.title.contains("Muted"))
        XCTAssertTrue(output.isEnabled)
    }

    @MainActor
    func testSoundOutputDropdownSurvivesRefreshAndSelectsDevice() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let view = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        let devices = [
            SoundOutputDevice(id: 78, uid: "speakers", name: "MacBook Pro Speakers", isDefault: false, volume: 0.4),
            SoundOutputDevice(id: 90, uid: "headphones", name: "Headphones", isDefault: true, volume: 0.7),
        ]
        let app = SoundPlaybackApp(
            processObjectID: 116,
            pid: pid,
            displayPID: pid,
            name: "Browser",
            bundleIdentifier: "example.browser",
            kind: .audio,
            volume: 1,
            selectedOutputUID: nil,
            routeState: .system
        )
        var selectedUID: String?
        var masterVolumeChange: (Float, String)?
        var masterPlaybackToggleCount = 0
        var playbackIdentifier: String?
        var pinnedMedia: SoundPermanentMedia?
        view.onOutputChange = { uid, _ in selectedUID = uid }
        view.onDeviceVolumeChange = { volume, uid in masterVolumeChange = (volume, uid) }
        view.onMasterPlaybackToggle = { masterPlaybackToggleCount += 1 }
        view.onPlaybackToggle = { playbackIdentifier = $0 }
        view.onPermanentChange = { media, enabled in if enabled { pinnedMedia = media } }
        let musicCandidate = SoundPermanentMedia(bundleIdentifier: "com.apple.Music", name: "Music", kind: .music)
        view.update(SoundControlSnapshot(
            apps: [app],
            devices: devices,
            permanentCandidates: [musicCandidate],
            message: "1 active audio app"
        ))

        try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Master: Pause Browser")).performClick(nil)
        try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Pause Browser")).performClick(nil)
        XCTAssertEqual(masterPlaybackToggleCount, 1)
        XCTAssertEqual(playbackIdentifier, "example.browser")

        try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Manage permanent media")).performClick(nil)
        try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Pin Music")).performClick(nil)
        XCTAssertEqual(pinnedMedia, musicCandidate)

        let masterSlider = try XCTUnwrap(firstSlider(in: view, accessibilityLabel: "Master volume"))
        XCTAssertEqual(masterSlider.floatValue, 0.7, accuracy: 0.001)
        masterSlider.floatValue = 0.45
        XCTAssertTrue(masterSlider.sendAction(masterSlider.action, to: masterSlider.target))
        let masterChange = try XCTUnwrap(masterVolumeChange)
        XCTAssertEqual(masterChange.0, 0.45, accuracy: 0.001)
        XCTAssertEqual(masterChange.1, "headphones")

        let initialOutputButton = try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Choose app audio output"))

        let routedApp = SoundPlaybackApp(
            processObjectID: app.processObjectID,
            pid: app.pid,
            displayPID: app.displayPID,
            name: app.name,
            bundleIdentifier: app.bundleIdentifier,
            kind: app.kind,
            volume: app.volume,
            selectedOutputUID: nil,
            routeState: .starting
        )
        view.update(SoundControlSnapshot(apps: [routedApp], devices: devices, message: "1 active audio app"))
        let secondButton = try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Choose app audio output"))

        XCTAssertTrue(initialOutputButton === secondButton)
        let hoverEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        secondButton.mouseEntered(with: hoverEvent)
        let speakersButton = try XCTUnwrap(firstButton(in: view, accessibilityLabel: "MacBook Pro Speakers"))
        speakersButton.performClick(nil)
        XCTAssertEqual(selectedUID, "speakers")

        let deviceSlider = try XCTUnwrap(firstSlider(in: view, accessibilityLabel: "Output device volume"))
        XCTAssertEqual(deviceSlider.floatValue, 0.4, accuracy: 0.001)
    }

    @MainActor
    func testSoundRefreshDoesNotMoveAppSliderDuringDrag() throws {
        let view = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        let music = SoundPlaybackApp(processObjectID: 1, pid: 42, displayPID: 0, name: "Music",
            bundleIdentifier: "com.apple.Music", kind: .music, volume: 0.8,
            selectedOutputUID: nil, routeState: .system)
        let snapshot = SoundControlSnapshot(apps: [music])
        view.update(snapshot)
        let slider = try XCTUnwrap(firstSlider(in: view, accessibilityLabel: "App volume"))
        slider.cell?.isHighlighted = true
        slider.floatValue = 0.25
        view.update(snapshot)
        XCTAssertEqual(slider.floatValue, 0.25, accuracy: 0.001)
        XCTAssertTrue(firstSlider(in: view, accessibilityLabel: "App volume") === slider)
        slider.cell?.isHighlighted = false
        view.update(snapshot)
        XCTAssertEqual(slider.floatValue, 0.8, accuracy: 0.001)
    }

    @MainActor
    func testInactivePinnedMediaHidesNonfunctionalControls() throws {
        let view = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        var music = SoundPlaybackApp(
            processObjectID: 0,
            pid: 0,
            displayPID: 0,
            name: "Music",
            bundleIdentifier: "com.apple.Music",
            kind: .music,
            volume: 1,
            selectedOutputUID: nil,
            routeState: .system
        )
        music.isActive = false
        music.isPermanent = true
        view.update(SoundControlSnapshot(apps: [music], message: "No app is currently playing audio"))

        let appSliders = allSubviews(in: view)
            .compactMap { $0 as? NSSlider }
            .filter { $0.accessibilityLabel() == "App volume" || $0.accessibilityLabel() == "Output device volume" }
        XCTAssertEqual(appSliders.count, 2)
        XCTAssertTrue(appSliders.allSatisfy(\.isHidden))
        let output = try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Choose app audio output"))
        XCTAssertTrue(output.isHidden)

        if let path = ProcessInfo.processInfo.environment["THERMOBAR_INACTIVE_SOUND_PREVIEW_PATH"] {
            let container = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
            container.appearance = NSAppearance(named: .aqua)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            container.installSoundControlView(view)
            container.selectTab(at: 2)
            let bitmap = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
            container.cacheDisplay(in: container.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testDashboardRendersAtMenuSize() throws {
        let snapshot = HardwareSnapshot(
            timestamp: Date(),
            temperatureReadings: [
                TemperatureReading(key: "Te01", celsius: 62, group: .cpu),
                TemperatureReading(key: "Tp01", celsius: 71, group: .cpu),
                TemperatureReading(key: "Tp02", celsius: 92, group: .cpu),
                TemperatureReading(key: "Tg01", celsius: 64, group: .gpu),
                TemperatureReading(key: "Tf01", celsius: 58, group: .hotspot),
            ],
            cpu: TemperatureSummary(maximum: 42, mean: 40, count: 23),
            gpu: TemperatureSummary(maximum: 41, mean: 39, count: 84),
            hottest: TemperatureReading(key: "Tp01", celsius: 42, group: .cpu),
            fanRPM: [0, 0],
            cpuUsage: 0.163,
            cpuBreakdown: CPUUsageBreakdown(total: 0.163, system: 0.043, user: 0.12, idle: 0.837),
            gpuMetrics: GPUMetrics(usage: 0.47, rendererUsage: 0.41, tilerUsage: 0.18),
            powerMetrics: PowerMetrics(cpuWatts: 4.8, gpuWatts: 2.3),
            topApps: [
                TopAppMetrics(name: "Google Chrome", cpuPercent: 48, memoryBytes: 3_200_000_000, energyImpact: 52.8,
                    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
                TopAppMetrics(name: "com.apple.appkit.xpc.openAndSavePanelService", cpuPercent: 27, memoryBytes: 2_100_000_000, isBackground: true, energyImpact: 31.6),
                TopAppMetrics(name: "WindowServer", cpuPercent: 18, memoryBytes: 820_000_000, isBackground: true, energyImpact: 22.4),
                TopAppMetrics(name: "Music", cpuPercent: 4, memoryBytes: 410_000_000, isBackground: true, energyImpact: 5.1),
                TopAppMetrics(name: "Finder", cpuPercent: 2, memoryBytes: 220_000_000, isBackground: true, energyImpact: 2.3),
            ],
            memoryUsage: 0.526,
            memoryMetrics: MemoryMetrics(
                usage: 0.526,
                appBytes: 7_200_000_000,
                wiredBytes: 3_900_000_000,
                compressedBytes: 9_200_000_000
            ),
            memoryLeakAssessment: nil,
            memoryPressure: .normal,
            storageMetrics: StorageMetrics(usedBytes: 401_000_000_000, totalBytes: 2_000_000_000_000, usage: 0.201),
            batteryMetrics: BatteryMetrics(
                level: 0.80,
                powerSource: "Battery",
                maximumCapacity: 0.938,
                cycleCount: 102,
                temperature: 27.5,
                powerWatts: 8.4,
                isCharging: false,
                remainingEnergyWh: 68.2,
                estimatedMinutesRemaining: 487,
                estimateConfidence: .adaptive,
                history: (0..<13).map { index in
                    BatteryHistoryPoint(
                        timestamp: Date().addingTimeInterval(Double(index - 12) * 30 * 60),
                        level: 0.94 - Double(index) * 0.005
                    )
                }
            ),
            networkMetrics: NetworkMetrics(
                interfaceName: "en0",
                displayName: "Wi-Fi",
                localIPAddress: "192.0.2.10",
                uploadBytesPerSecond: 831_300,
                downloadBytesPerSecond: 53_500_000,
                signalRSSI: -52,
                noiseDBM: -91,
                transmitRateMbps: 1_200,
                latencyMilliseconds: 24
            ),
            respondingTemperatureSensors: 320,
            discoveredTemperatureSensors: 342,
            thermalState: .nominal
        )
        let view = SystemDetailsView(frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize))
        view.appearance = NSAppearance(named: .aqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        let history: [HistoricalMetricsPoint] = (0..<96).map { index in
            var values: [HistoricalMetric: Double] = [:]
            values[.cpuUsage] = 0.12 + Double(index % 12) / 100
            values[.cpuWatts] = 4 + Double(index % 8) / 4
            values[.gpuUsage] = 0.20 + Double(index % 18) / 100
            values[.gpuWatts] = 2 + Double(index % 6) / 5
            values[.memoryUsage] = 0.48 + Double(index % 8) / 100
            values[.storageUsage] = 0.20 + Double(index) / 100_000
            values[.batteryLevel] = 0.94 - Double(index) * 0.0015
            values[.batteryWatts] = 7 + Double(index % 5) / 2
            values[.networkUpload] = 500_000 + Double(index % 10) * 80_000
            values[.networkDownload] = 8_000_000 + Double(index % 16) * 1_000_000
            values[.networkLatency] = 18 + Double(index % 7)
            return HistoricalMetricsPoint(
                timestamp: snapshot.timestamp.addingTimeInterval(Double(index - 95) * 15 * 60),
                values: values
            )
        }
        view.update(
            snapshot: snapshot,
            history: history
        )
        let fanView = FanControlView(frame: NSRect(origin: .zero, size: FanControlView.preferredSize))
        fanView.update(FanControlViewState(
            selectedMode: .manual,
            activeMode: .manual,
            profile: .balanced,
            helperReady: true,
            helperRegistration: "Installed",
            helperFeedback: .confirmed,
            applyFeedback: .confirmed,
            status: "✓ Manual confirmed and active",
            systemBaselineRPM: 2_100,
            capabilities: [
                FanCapability(index: 0, minimumRPM: 1_350, maximumRPM: 5_777, modeKey: "F0md"),
                FanCapability(index: 1, minimumRPM: 1_350, maximumRPM: 5_777, modeKey: "F1md"),
            ],
            targets: [FanTarget(index: 0, rpm: 3_200), FanTarget(index: 1, rpm: 3_200)],
            manualTargets: [FanTarget(index: 0, rpm: 3_200), FanTarget(index: 1, rpm: 3_200)],
            actualRPM: [2_950, 3_020]
        ))
        fanView.updateTemperatures(
            snapshot.temperatureReadings,
            cpuUsage: snapshot.cpuUsage,
            gpuUsage: snapshot.gpuMetrics?.usage,
            topApps: snapshot.topApps,
            thermalState: snapshot.thermalState
        )
        view.installFanControlView(fanView)
        let soundView = SoundControlView(frame: NSRect(origin: .zero, size: SoundControlView.preferredSize))
        soundView.update(SoundControlSnapshot(
            apps: [
                SoundPlaybackApp(
                    processObjectID: 91,
                    pid: ProcessInfo.processInfo.processIdentifier,
                    displayPID: ProcessInfo.processInfo.processIdentifier,
                    name: "Apple Music",
                    bundleIdentifier: "com.apple.Music",
                    kind: .music,
                    volume: 0.72,
                    selectedOutputUID: "headphones",
                    routeState: .routed
                ),
                SoundPlaybackApp(
                    processObjectID: 92,
                    pid: ProcessInfo.processInfo.processIdentifier,
                    displayPID: ProcessInfo.processInfo.processIdentifier,
                    name: "Racing Game",
                    bundleIdentifier: "example.game",
                    kind: .game,
                    volume: 0.88,
                    selectedOutputUID: nil,
                    routeState: .system
                ),
            ],
            devices: [
                SoundOutputDevice(id: 1, uid: "speakers", name: "MacBook Pro Speakers", isDefault: true, volume: 0.6),
                SoundOutputDevice(id: 2, uid: "headphones", name: "Bluetooth Headphones", isDefault: false, volume: 0.8),
            ],
            message: "2 active audio apps"
        ))
        view.installSoundControlView(soundView)

        view.selectTab(at: 0)
        let energyButtons = view.subviews.compactMap { $0 as? EnergyAppActionButton }
        let chromeButton = try XCTUnwrap(energyButtons.first { $0.app?.name == "Google Chrome" })
        XCTAssertFalse(chromeButton.isHidden)
        XCTAssertTrue(chromeButton.isEnabled)
        XCTAssertTrue(chromeButton.toolTip?.contains("/Applications/Google Chrome.app") == true)
        var selectedApp: TopAppMetrics?
        view.onOpenEnergyApp = { app, _ in selectedApp = app }
        chromeButton.performClick(nil)
        XCTAssertEqual(selectedApp?.applicationURL?.path, "/Applications/Google Chrome.app")
        XCTAssertGreaterThanOrEqual(chromeButton.frame.minY, 300)
        XCTAssertLessThanOrEqual(chromeButton.frame.maxY, view.bounds.height)
        view.selectTab(at: 1)
        XCTAssertTrue(energyButtons.allSatisfy(\.isHidden))

        XCTAssertGreaterThan(fanView.frame.height, FanControlView.preferredSize.height)
        XCTAssertEqual(view.subviews.compactMap { $0 as? NSScrollView }.count, 2)

        if let path = ProcessInfo.processInfo.environment["THERMOBAR_PREVIEW_PATH"] {
            let wasHidden = fanView.isHidden
            fanView.isHidden = false
            let bitmap = try XCTUnwrap(fanView.bitmapImageRepForCachingDisplay(in: fanView.bounds))
            fanView.cacheDisplay(in: fanView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("fan-sensors.png")
            try png.write(to: url)
            fanView.isHidden = wasHidden
        }

        for tabIndex in 0..<SystemDetailsView.tabCount {
            view.selectTab(at: tabIndex)
            view.selectHistoryRange(at: tabIndex % MetricHistoryRange.allCases.count)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 4_000)

            if let path = ProcessInfo.processInfo.environment["THERMOBAR_PREVIEW_PATH"] {
                let url = URL(fileURLWithPath: path)
                let tabURL = url.deletingPathExtension()
                    .appendingPathExtension("tab-\(tabIndex).png")
                try png.write(to: tabURL)
            }
        }

        view.selectTab(at: 3)
        XCTAssertFalse(fanView.isHidden)
        view.selectTab(at: 0)
        XCTAssertTrue(fanView.isHidden)

        view.selectSystemPage(at: 1)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isInsightsTabSelected)
        XCTAssertFalse(view.isMoodTabSelected)
        XCTAssertEqual(view.frame.height, 248)
        XCTAssertTrue(energyButtons.allSatisfy(\.isHidden))
        let sections = try XCTUnwrap(view.subviews.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == "System section" })
        XCTAssertFalse(sections.isHidden)
        XCTAssertEqual(sections.label(forSegment: 0), "Overview")
        XCTAssertEqual(sections.label(forSegment: 1), "Insights")
        let exportButton = try XCTUnwrap(firstButton(in: view, accessibilityLabel: "Export diagnostic report"))
        XCTAssertFalse(exportButton.isHidden)
        XCTAssertTrue(exportButton.title.isEmpty)
        XCTAssertNotNil(exportButton.image)
        XCTAssertLessThan(exportButton.frame.minY, 50)
        XCTAssertFalse(exportButton.frame.intersects(sections.frame))
        var exports = 0
        view.onExportDiagnostics = { exports += 1 }
        exportButton.performClick(nil)
        XCTAssertEqual(exports, 1)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            view.layer?.backgroundColor = (appearance == .aqua ? NSColor.white : NSColor(calibratedWhite: 0.13, alpha: 1)).cgColor
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 4_000)
            if ProcessInfo.processInfo.environment["THERMOBAR_PREVIEW_PATH"] != nil {
                try png.write(to: URL(fileURLWithPath: "/private/tmp/mybar-system-insights-\(appearance.rawValue).png"))
            }
        }
        view.selectTab(at: 2)
        XCTAssertTrue(sections.isHidden)
        XCTAssertTrue(exportButton.isHidden)
        view.selectTab(at: 0)
        XCTAssertTrue(view.isInsightsTabSelected, "System remembers its own selected section")
        view.selectSystemPage(at: 0)
        XCTAssertFalse(view.isInsightsTabSelected)
        XCTAssertEqual(view.frame.height, SystemDetailsView.systemSectionHeight)
        XCTAssertTrue(exportButton.isHidden)
        XCTAssertFalse(chromeButton.isHidden)
    }

    private func firstButton(in view: NSView, accessibilityLabel: String) -> NSButton? {
        if let button = view as? NSButton,
           button.accessibilityLabel() == accessibilityLabel {
            return button
        }
        for subview in view.subviews {
            if let button = firstButton(in: subview, accessibilityLabel: accessibilityLabel) { return button }
        }
        return nil
    }

    private func firstSlider(in view: NSView, accessibilityLabel: String) -> NSSlider? {
        if let slider = view as? NSSlider,
           slider.accessibilityLabel() == accessibilityLabel {
            return slider
        }
        for subview in view.subviews {
            if let slider = firstSlider(in: subview, accessibilityLabel: accessibilityLabel) { return slider }
        }
        return nil
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(in:))
    }
}
