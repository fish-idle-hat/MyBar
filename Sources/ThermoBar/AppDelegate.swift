import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pollQueue = DispatchQueue(label: "ThermoBar.sensor-poll", qos: .utility)
    private let statusItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: 108)
        item.autosaveName = "ThermoBar.StatusItem"
        item.behavior = [.removalAllowed]
        return item
    }()
    private let dashboardView = StatusDashboardView(frame: NSRect(x: 0, y: 0, width: 108, height: 22))
    private let systemDetailsView = SystemDetailsView(
        frame: NSRect(origin: .zero, size: SystemDetailsView.preferredSize)
    )
    private let fanControlManager = FanControlManager()
    private let fanControlView = FanControlView(
        frame: NSRect(origin: .zero, size: FanControlView.preferredSize)
    )
    private let soundControlManager = SoundControlManager()
    private let typingFeedbackManager = TypingFeedbackManager()
    private let trackpadGestureManager = TrackpadGestureManager()
    private lazy var settingsWindow = MyBarSettingsWindowController(manager: trackpadGestureManager)
    private let soundControlView = SoundControlView(
        frame: NSRect(origin: .zero, size: SoundControlView.preferredSize)
    )
    private let historyStore = HistoricalMetricsStore()
    private let thermalPredictor = ThermalPredictor()
    private let personalBaseline = PersonalBaseline()
    private let alertFilter = SustainedAlertFilter()
    private let incidentRecorder = IncidentRecorder()
    private let moodCompassManager = MoodCompassManager()
    private let moodCompassView = MoodCompassView(frame: NSRect(origin: .zero, size: MoodCompassView.preferredSize))
    private let petController = DesktopPetController()
    private let petControlView = PetControlView(frame: NSRect(x: 0, y: 0, width: 360, height: PetControlView.preferredHeight))

    private var monitor: HardwareMonitor?
    private var timer: Timer?
    private var soundTimer: Timer?
    private var isRefreshing = false
    private var isMenuOpen = false
    private var forceFullSensorsNextRefresh = false
    private var forceDetailsNextRefresh = false
    private var lastSnapshot: HardwareSnapshot?
    private var hasLoadedHistory = false
    private var currentPrediction: ThermalPrediction?
    private var currentAlerts = StableAlertState()
    private var monitoringMode: MonitoringMode = {
        guard let value = UserDefaults.standard.string(forKey: "ThermoBar.MonitoringMode"),
              let mode = MonitoringMode(rawValue: value)
        else { return .balanced }
        return mode
    }()
    private var monitoringModeItems: [MonitoringMode: NSMenuItem] = [:]
    private let menuBarOrganizer = MenuBarOrganizer()
    private lazy var organizerHost = OrganizerHostView(details: systemDetailsView, manager: menuBarOrganizer)

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureFanControl()
        configureSoundControl()
        configureMoodCompass()
        configurePet()
        trackpadGestureManager.start()
        configureMenu()
        showLoadingMenu()
        dashboardView.startRPMStartupAnimation()
        refresh()

        rebuildRefreshTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(prepareForSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarOrganizer.stop()
        timer?.invalidate()
        soundTimer?.invalidate()
        historyStore.flush()
        personalBaseline.flush()
        incidentRecorder.flush()
        moodCompassManager.stop()
        typingFeedbackManager.stop()
        trackpadGestureManager.stop()
        petController.stop()
        soundControlManager.stopAll()
        fanControlManager.restoreBeforeTermination()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = nil
        dashboardView.frame = button.bounds
        dashboardView.autoresizingMask = [.width, .height]
        button.addSubview(dashboardView)
        button.setAccessibilityLabel("MyBar system monitor")
    }

    private func configureMenu() {
        menuBarOrganizer.mainItemFrame = { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        menuBarOrganizer.onDismissMenu = { [weak self] in self?.statusItem.menu?.cancelTracking() }
        systemDetailsView.onHistoryRangeChange = { [weak self] range in
            guard let self, let snapshot = self.lastSnapshot else { return }
            self.systemDetailsView.updateHistory(self.historyStore.history(for: range, at: snapshot.timestamp))
        }
        systemDetailsView.onSectionChange = { [weak self] in
            self?.sectionDidChange()
        }
        systemDetailsView.onExportDiagnostics = { [weak self] in
            self?.exportDiagnostics()
        }
        systemDetailsView.onHeightChange = { [weak self] in
            self?.organizerHost.resizeForDetails()
            self?.statusItem.menu?.update()
        }
        systemDetailsView.onOpenReplay = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
        }
        systemDetailsView.onOpenEnergyApp = { [weak self] app, reveal in
            self?.statusItem.menu?.cancelTracking()
            DispatchQueue.main.async { EnergyAppNavigation.open(app, revealOnly: reveal) }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let detailsItem = NSMenuItem()
        detailsItem.view = organizerHost
        menu.addItem(detailsItem)
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let modeMenu = NSMenu()
        for mode in MonitoringMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selectMonitoringMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == monitoringMode ? .on : .off
            modeMenu.addItem(item)
            monitoringModeItems[mode] = item
        }
        let modeItem = NSMenuItem(title: "Monitoring Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit MyBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsWindow.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.trackpadGestureManager.refresh()
        }
    }

    private func configureFanControl() {
        systemDetailsView.installFanControlView(fanControlView)
        fanControlManager.onStateChange = { [weak self] state in
            self?.fanControlView.update(state)
            self?.dashboardView.setFanControlPresentation(
                systemBaselineRPM: state.systemBaselineRPM,
                isOverrideActive: state.isFanOverrideActive
            )
        }
        fanControlView.onModeChange = { [weak self] mode in
            self?.fanControlManager.select(mode: mode)
            self?.fanControlManager.applySelection()
        }
        fanControlView.onProfileChange = { [weak self] profile in
            guard let self else { return }
            self.fanControlManager.select(profile: profile)
            if self.fanControlManager.state.selectedMode == .smart {
                self.fanControlManager.applySelection()
            }
        }
        fanControlView.onManualTargetsChange = { [weak self] targets in
            self?.fanControlManager.applyManualTargets(targets)
        }
        fanControlView.onEnableHelper = { [weak self] in self?.fanControlManager.enableHelper() }
        fanControlView.onRestoreSystem = { [weak self] in self?.fanControlManager.userRestoreSystem() }
        fanControlView.onSmartRulesChange = { [weak self] enabled in
            self?.fanControlManager.setSmartRulesEnabled(enabled)
        }
        fanControlView.update(fanControlManager.state)
    }

    private func configureSoundControl() {
        let feedback = soundControlView.typingFeedbackView
        typingFeedbackManager.onChange = { [weak feedback] in feedback?.update($0) }
        typingFeedbackManager.onPermissionPrompt = { [weak self] in self?.statusItem.menu?.cancelTracking() }
        feedback.onEnable = { [weak self] enabled in
            guard let self else { return }
            DispatchQueue.main.async { self.typingFeedbackManager.setEnabled(enabled) }
        }
        feedback.onSound = { [weak self] in self?.typingFeedbackManager.selectSound($0) }
        feedback.onVolume = { [weak self] in self?.typingFeedbackManager.setVolume($0) }
        feedback.onPreview = { [weak self] in self?.typingFeedbackManager.preview() }
        feedback.onConfirm = { [weak self] in self?.typingFeedbackManager.confirmHeadphones() }
        feedback.onRetry = { [weak self] in self?.typingFeedbackManager.refresh() }
        feedback.onPermission = { [weak self] in self?.typingFeedbackManager.requestPermission(openSettings: true) }
        typingFeedbackManager.start()
        soundControlView.savedSceneNames = { [weak self] in self?.soundControlManager.savedScenes.map(\.name) ?? [] }
        soundControlView.onSaveScene = { [weak self] in self?.soundControlManager.saveScene(named: $0) }
        soundControlView.onApplyScene = { [weak self] in self?.soundControlManager.applyScene(named: $0) }
        systemDetailsView.installSoundControlView(soundControlView)
        soundControlManager.onSnapshotChange = { [weak self] snapshot in
            guard let self else { return }
            self.petController.updateMusic(snapshot)
            if self.isMenuOpen && self.systemDetailsView.isSoundTabSelected { self.soundControlView.update(snapshot) }
        }
        soundControlView.onVolumeChange = { [weak self] volume, pid in
            self?.soundControlManager.setVolume(volume, for: pid)
        }
        soundControlView.onOutputChange = { [weak self] uid, pid in
            self?.soundControlManager.setOutput(uid: uid, for: pid)
        }
        soundControlView.onDeviceVolumeChange = { [weak self] volume, uid in
            self?.soundControlManager.setDeviceVolume(volume, for: uid)
        }
        soundControlView.onMasterPlaybackToggle = { [weak self] in
            self?.soundControlManager.toggleMasterPlayback()
        }
        soundControlView.onPlaybackToggle = { [weak self] identifier in
            self?.soundControlManager.togglePlayback(for: identifier)
        }
        soundControlView.onPermanentChange = { [weak self] media, enabled in
            self?.soundControlManager.setPermanent(media, enabled: enabled)
        }
        soundControlView.onPermanentMove = { [weak self] identifier, direction in
            self?.soundControlManager.movePermanent(bundleIdentifier: identifier, direction: direction)
        }
    }

    @objc private func refreshSound() {
        if isMenuOpen && systemDetailsView.isSoundTabSelected {
            soundControlManager.refresh()
        } else if petController.needsMusicMonitoring {
            soundControlManager.refreshMusicActivity { [weak self] in self?.petController.updateMusicPlaying($0) }
        }
    }

    private func configurePet() {
        systemDetailsView.installPetView(petControlView)
        petController.onChange = { [weak self] settings, activity in self?.petControlView.update(settings: settings, activity: activity) }
        petController.onMonitoringChange = { [weak self] in
            guard let self else { return }
            if self.petController.needsMusicMonitoring { self.startSoundTimerIfNeeded() } else { self.stopSoundTimer() }
        }
        petControlView.onSettingsChange = { [weak self] in self?.petController.configure($0) }
        petControlView.onRecenter = { [weak self] in self?.petController.recenter() }
        petController.start()
    }

    private func configureMoodCompass() {
        systemDetailsView.installMoodCompassView(moodCompassView)
        moodCompassManager.onChange = { [weak self] presentation in
            guard let self else { return }
            self.moodCompassView.update(presentation)
            self.dashboardView.setReadiness(CompassMenuReadiness(presentation))
            if let snapshot = self.lastSnapshot { self.updateStatusDescription(snapshot) }
        }
        moodCompassView.onEnable = { [weak self] in self?.moodCompassManager.setEnabled($0) }
        moodCompassView.onSource = { [weak self] source, enabled in
            guard let self else { return }
            if enabled, ["typing", "calendar", "reminders", "daylight"].contains(source) {
                self.statusItem.menu?.cancelTracking()
                DispatchQueue.main.async { self.moodCompassManager.setSource(source, enabled: enabled) }
            } else { self.moodCompassManager.setSource(source, enabled: enabled) }
        }
        moodCompassView.onContext = { [weak self] in self?.moodCompassManager.setContext($0) }
        moodCompassView.onCheckIn = { [weak self] in self?.moodCompassManager.recordCheckIn($0) }
        moodCompassView.onBeginFocus = { [weak self] in self?.moodCompassManager.beginFocus() }
        moodCompassView.onFinishFocus = { [weak self] in self?.moodCompassManager.finishFocus($0) }
        moodCompassView.onOpenPermissions = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                NSWorkspace.shared.open(url)
            }
        }
        moodCompassView.onDelete = { [weak self] in
            self?.statusItem.menu?.cancelTracking()
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Delete Mood Compass data?"
                alert.informativeText = "Deletes local mood history, check-ins, baselines, saved models and review history. Monitoring will stop. Other MyBar data is not affected."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Delete Mood Data")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertSecondButtonReturn { self?.moodCompassManager.deleteAllData() }
            }
        }
        moodCompassManager.start()
    }

    private func startSoundTimerIfNeeded() {
        guard ((isMenuOpen && systemDetailsView.isSoundTabSelected) || petController.needsMusicMonitoring), soundTimer == nil else { return }
        refreshSound()
        let timer = Timer(timeInterval: 2.0, target: self, selector: #selector(refreshSound), userInfo: nil, repeats: true)
        timer.tolerance = 0.35
        RunLoop.main.add(timer, forMode: .common)
        soundTimer = timer
    }

    private func stopSoundTimer() {
        guard !petController.needsMusicMonitoring else { return }
        soundTimer?.invalidate()
        soundTimer = nil
    }

    private func rebuildRefreshTimer() {
        timer?.invalidate()
        let timer = Timer(
            timeInterval: monitoringMode.refreshInterval,
            target: self,
            selector: #selector(refresh),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = min(0.35, monitoringMode.refreshInterval * 0.15)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let mode = monitoringMode
        let forceFullSensors = forceFullSensorsNextRefresh
        let forceDetails = forceDetailsNextRefresh
        forceFullSensorsNextRefresh = false
        forceDetailsNextRefresh = false

        pollQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.monitor == nil {
                    self.monitor = try HardwareMonitor()
                }
                let snapshot = self.monitor!.readSnapshot(
                    mode: mode,
                    forceFullSensors: forceFullSensors,
                    forceDetails: forceDetails
                )
                DispatchQueue.main.async {
                    self.lastSnapshot = snapshot
                    self.isRefreshing = false
                    self.render(snapshot)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.render(error: error)
                }
            }
        }
    }

    private func render(_ snapshot: HardwareSnapshot) {
        petController.updateFans(snapshot.fanRPM)
        personalBaseline.update(snapshot)
        systemDetailsView.updatePersonalRange(personalBaseline.current)
        dashboardView.setMemoryPressure(snapshot.memoryPressure)
        let extractionFault = StatusDashboardView.isCoreDataIncomplete(
            temperature: snapshot.chipTemperature,
            cpuUsage: snapshot.cpuUsage,
            gpuUsage: snapshot.gpuMetrics?.usage,
            memoryUsage: snapshot.memoryUsage,
            fanRPM: snapshot.fanRPM
        )
        currentPrediction = thermalPredictor.update(temperature: snapshot.chipTemperature, at: snapshot.timestamp)
        currentAlerts = alertFilter.update(snapshot: snapshot, extractionFault: extractionFault)
        incidentRecorder.record(snapshot: snapshot, alerts: currentAlerts)
        fanControlManager.update(snapshot: snapshot, prediction: currentPrediction)
        if isMenuOpen, systemDetailsView.isFansTabSelected {
            fanControlView.updateTemperatures(
                snapshot.temperatureReadings,
                cpuUsage: snapshot.cpuUsage,
                gpuUsage: snapshot.gpuMetrics?.usage,
                topApps: snapshot.topApps,
                thermalState: snapshot.thermalState
            )
        }
        dashboardView.update(
            cpuUsage: snapshot.cpuUsage,
            gpuUsage: snapshot.gpuMetrics?.usage,
            memoryUsage: snapshot.memoryUsage,
            temperature: snapshot.chipTemperature,
            fanRPM: snapshot.fanRPM,
            batteryTemperature: snapshot.batteryMetrics?.temperature,
            wifiLatencyMilliseconds: snapshot.networkMetrics?.latencyMilliseconds,
            memoryLeakAssessment: snapshot.memoryLeakAssessment,
            stableAlerts: currentAlerts
        )
        dashboardView.setExtractionFault(currentAlerts.extractionFault)
        updateStatusDescription(snapshot)
        let completedHistoryBucket = historyStore.record(snapshot)
        guard isMenuOpen else { return }
        if completedHistoryBucket || !hasLoadedHistory {
            systemDetailsView.update(
                snapshot: snapshot,
                history: historyStore.history(for: systemDetailsView.selectedHistoryRange, at: snapshot.timestamp)
            )
            hasLoadedHistory = true
        } else {
            systemDetailsView.update(snapshot: snapshot)
        }
        systemDetailsView.updateIntelligence(
            prediction: currentPrediction,
            incidents: incidentRecorder.visibleIncidents,
            mode: monitoringMode
        )
    }

    private func render(error: Swift.Error) {
        dashboardView.showError()
        systemDetailsView.showError(String(describing: error))
    }

    private func showLoadingMenu() {
        dashboardView.showLoading()
        systemDetailsView.showLoading()
    }

    private func summaryLine(name: String, value: TemperatureSummary) -> String {
        String(
            format: "%-4@ Max %5.1f°C   Avg %5.1f°C   (%d sensors)",
            name as NSString,
            value.maximum,
            value.mean,
            value.count
        )
    }

    private func metricLine(name: String, value: Double?) -> String {
        let rendered = value.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable"
        return String(format: "%-18@ %@", name as NSString, rendered)
    }

    private func storageSummary() -> (used: Int64, available: Int64, total: Int64, usedPercent: Int)? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: keys),
              let totalValue = values.volumeTotalCapacity,
              totalValue > 0
        else { return nil }

        let total = Int64(totalValue)
        let reportedAvailable = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
            ?? 0
        let available = min(total, max(0, reportedAvailable))
        let used = total - available
        let usedPercent = Int((Double(used) / Double(total) * 100).rounded())
        return (used, available, total, usedPercent)
    }

    private func updateStatusDescription(_ snapshot: HardwareSnapshot) {
        let primary = dashboardView.primaryMetricExplanation()
        statusItem.button?.toolTip = "MyBar · \(monitoringMode.rawValue) monitoring\n\(primary)"
        statusItem.button?.setAccessibilityValue("\(primary) \(accessibilitySummary(snapshot))")
    }

    private func accessibilitySummary(_ snapshot: HardwareSnapshot) -> String {
        let cpu = snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded())) percent CPU" } ?? "CPU unavailable"
        let gpu = snapshot.gpuMetrics.map { "\(Int(($0.usage * 100).rounded())) percent GPU" } ?? "GPU unavailable"
        let memoryUsage = snapshot.memoryUsage.map { "\(Int(($0 * 100).rounded())) percent memory" } ?? "memory usage unavailable"
        let memoryPressure = "memory pressure \(snapshot.memoryPressure.displayName.lowercased())"
        let temperature = snapshot.chipTemperature.map { "\(Int($0.rounded())) degrees Celsius" } ?? "temperature unavailable"
        let battery = snapshot.batteryMetrics?.temperature.map {
            let warning = StatusDashboardView.isBatteryOverheat($0) ? ", battery overheat warning" : ""
            return "battery \(Int($0.rounded())) degrees Celsius\(warning)"
        } ?? "battery temperature unavailable"
        let latency = snapshot.networkMetrics.flatMap(\.latencyMilliseconds).map {
            "Wi-Fi latency \(Int($0.rounded())) milliseconds"
        } ?? "Wi-Fi latency unavailable"
        let memoryLeak = snapshot.memoryLeakAssessment.map {
            String(format: "possible memory leak, app memory increased %.1f gigabytes", Double($0.growthBytes) / 1_000_000_000)
        }
        let fans = snapshot.fanRPM.enumerated().map { index, rpm in
            let side = index == 0 ? "left" : index == 1 ? "right" : "fan \(index + 1)"
            return rpm.map { "\(side) fan \(Int($0.rounded())) RPM" } ?? "\(side) fan unavailable"
        }.joined(separator: ", ")
        return [cpu, gpu, memoryUsage, memoryPressure, memoryLeak, temperature, battery, latency, fans]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func label(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
        }
        return item
    }

    @objc private func refreshNow() {
        dashboardView.startRPMStartupAnimation()
        forceDetailsNextRefresh = true
        if systemDetailsView.isFansTabSelected { forceFullSensorsNextRefresh = true }
        refresh()
    }

    @objc private func selectMonitoringMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MonitoringMode(rawValue: raw),
              mode != monitoringMode
        else { return }
        monitoringMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "ThermoBar.MonitoringMode")
        for (candidate, item) in monitoringModeItems { item.state = candidate == mode ? .on : .off }
        rebuildRefreshTimer()
        refresh()
    }

    private func sectionDidChange() {
        if systemDetailsView.isMoodTabSelected { moodCompassManager.refreshPresentation() }
        if systemDetailsView.isFansTabSelected {
            forceFullSensorsNextRefresh = true
            forceDetailsNextRefresh = true
            refresh()
        }
        if systemDetailsView.isSoundTabSelected {
            startSoundTimerIfNeeded()
        } else {
            stopSoundTimer()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        systemDetailsView.setMenuVisible(true)
        typingFeedbackManager.resumeIfAuthorized()
        if systemDetailsView.isMoodTabSelected { moodCompassManager.refreshPresentation() }
        menuBarOrganizer.refresh()
        isMenuOpen = true
        if let snapshot = lastSnapshot {
            systemDetailsView.update(
                snapshot: snapshot,
                history: historyStore.history(for: systemDetailsView.selectedHistoryRange, at: snapshot.timestamp)
            )
            systemDetailsView.updateIntelligence(
                prediction: currentPrediction,
                incidents: incidentRecorder.visibleIncidents,
                mode: monitoringMode
            )
            if systemDetailsView.isFansTabSelected {
                fanControlView.updateTemperatures(
                    snapshot.temperatureReadings,
                    cpuUsage: snapshot.cpuUsage,
                    gpuUsage: snapshot.gpuMetrics?.usage,
                    topApps: snapshot.topApps,
                    thermalState: snapshot.thermalState
                )
            }
        }
        forceDetailsNextRefresh = true
        if systemDetailsView.isFansTabSelected { forceFullSensorsNextRefresh = true }
        startSoundTimerIfNeeded()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        systemDetailsView.setMenuVisible(false)
        typingFeedbackManager.endPreview()
        soundControlView.dismissTypingSoundPicker()
        isMenuOpen = false
        stopSoundTimer()
    }

    private func exportDiagnostics() {
        let report = DiagnosticReportBuilder.make(
            snapshot: lastSnapshot,
            mode: monitoringMode,
            prediction: currentPrediction,
            incidents: incidentRecorder.visibleIncidents,
            fanState: fanControlManager.state
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MyBar-Diagnostic-\(Self.fileDateFormatter.string(from: Date())).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Unable to Export Diagnostic Report"
            alert.runModal()
        }
    }

    @objc private func prepareForSleep() {
        fanControlManager.restoreForSleep()
    }

    @objc private func retry() {
        pollQueue.async { [weak self] in self?.monitor = nil }
        refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
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
}
