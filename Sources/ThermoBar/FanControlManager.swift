import AppKit
import FanControlProtocol
import Foundation
import Security

enum FanControlMode: Int, CaseIterable {
    case system
    case manual
    case smart

    var displayName: String {
        switch self {
        case .system: return "System"
        case .manual: return "Manual"
        case .smart: return "Auto Boost"
        }
    }
}

enum FanControlFeedback {
    case idle
    case working
    case confirmed
    case failed
}

struct FanControlViewState {
    var selectedMode: FanControlMode = .system
    var activeMode: FanControlMode = .system
    var profile: FanResponseProfile = .balanced
    var activeProfile: FanResponseProfile?
    var helperReady = false
    var helperRegistration = "Not enabled"
    var helperFeedback: FanControlFeedback = .idle
    var applyFeedback: FanControlFeedback = .idle
    var status = "Monitoring remains independent"
    var systemBaselineRPM: Double?
    var capabilities: [FanCapability] = []
    var targets: [FanTarget] = []
    var manualTargets: [FanTarget] = []
    var actualRPM: [Double?] = []
    var smartRulesEnabled = false
    var smartRulesReason = "Disabled"

    var isFanOverrideActive: Bool {
        systemBaselineRPM != nil
            && !targets.isEmpty
            && (activeMode == .smart || activeMode == .manual)
    }
}

final class FanControlManager {
    var onStateChange: ((FanControlViewState) -> Void)?

    private static let installedHelperPath = "/Library/PrivilegedHelperTools/local.thermobar.fanhelper"
    private static let installedPlistPath = "/Library/LaunchDaemons/local.thermobar.fanhelper.plist"
    private static let smartRulesDefaultsKey = "ThermoBar.SmartRules.enabled"
    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?
    private var latestSnapshot: HardwareSnapshot?
    private var commandInFlight = false
    private(set) var state = FanControlViewState()

    init() {
        state.smartRulesEnabled = UserDefaults.standard.bool(forKey: Self.smartRulesDefaultsKey)
        refreshRegistrationState()
        if helperIsInstalled {
            state.helperFeedback = .working
            state.status = "Confirming helper connection…"
            connect()
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
        connection?.invalidate()
    }

    func update(snapshot: HardwareSnapshot, prediction: ThermalPrediction? = nil) {
        latestSnapshot = snapshot
        state.actualRPM = snapshot.fanRPM
        publish()

        guard state.activeMode == .smart else { return }
        guard snapshot.thermalState != .serious, snapshot.thermalState != .critical else {
            restoreSystem(reason: "Thermal safety fallback: macOS control restored")
            return
        }
        guard let temperature = snapshot.chipTemperature else {
            restoreSystem(reason: "Temperature unavailable: macOS control restored")
            return
        }
        if state.smartRulesEnabled {
            let decision = SmartRuleEngine.decide(snapshot: snapshot, prediction: prediction)
            state.profile = decision.profile
            state.activeProfile = decision.profile
            state.smartRulesReason = "\(decision.profile.displayName) · \(decision.reason)"
        }
        publish()
        let predictiveTemperature = prediction.flatMap { prediction -> Double? in
            guard prediction.slopePerMinute > 0.25 else { return nil }
            return min(90, temperature + prediction.slopePerMinute * 2)
        }
        updateSmartTargets(temperature: max(temperature, predictiveTemperature ?? temperature))
    }

    func setSmartRulesEnabled(_ enabled: Bool) {
        state.smartRulesEnabled = enabled
        state.smartRulesReason = enabled ? "Waiting for Auto Boost" : "Disabled"
        UserDefaults.standard.set(enabled, forKey: Self.smartRulesDefaultsKey)
        if enabled, let snapshot = latestSnapshot, state.activeMode == .smart,
           let temperature = snapshot.chipTemperature {
            let decision = SmartRuleEngine.decide(snapshot: snapshot, prediction: nil)
            state.profile = decision.profile
            state.activeProfile = decision.profile
            state.smartRulesReason = "\(decision.profile.displayName) · \(decision.reason)"
            updateSmartTargets(temperature: temperature)
        }
        publish()
    }

    func select(mode: FanControlMode) {
        state.selectedMode = mode
        if mode == .manual { initializeManualTargetsIfNeeded() }
        markSelectionPendingIfNeeded()
        publish()
    }

    func select(profile: FanResponseProfile) {
        state.profile = profile
        markSelectionPendingIfNeeded()
        publish()
    }

    func enableHelper() {
        do {
            let installation = try prepareHelperInstallation()
            state.helperFeedback = .working
            state.status = "Waiting for administrator approval…"
            publish()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var error: NSDictionary?
                let result = NSAppleScript(source: installation.appleScript)?.executeAndReturnError(&error)
                try? FileManager.default.removeItem(at: installation.temporaryPlist)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if result == nil {
                        let message = (error?[NSAppleScript.errorMessage] as? String) ?? "Installation was cancelled"
                        self.state.status = "Helper setup failed: \(message)"
                        self.state.helperReady = false
                        self.state.helperFeedback = .failed
                        self.publish()
                        return
                    }
                    self.refreshRegistrationState()
                    self.state.helperFeedback = .working
                    self.state.status = "Connecting to helper…"
                    self.publish()
                    self.connect()
                }
            }
        } catch {
            state.status = "Helper setup failed: \(error.localizedDescription)"
            state.helperReady = false
            state.helperFeedback = .failed
            publish()
        }
    }

    func applySelection() {
        guard state.helperReady || state.selectedMode == .system else {
            state.status = "Enable the helper before applying fan control"
            state.applyFeedback = .failed
            publish()
            return
        }

        state.applyFeedback = .working
        state.status = "Applying \(selectedSettingName)…"
        publish()

        switch state.selectedMode {
        case .system:
            applySystemSelection()
        case .manual:
            initializeManualTargetsIfNeeded()
            captureSystemBaselineIfNeeded()
            sendTargets(
                state.manualTargets,
                confirmedMode: .manual,
                confirmation: "Manual"
            )
        case .smart:
            guard let snapshot = latestSnapshot,
                  let temperature = snapshot.chipTemperature,
                  snapshot.thermalState != .serious,
                  snapshot.thermalState != .critical
            else {
                state.applyFeedback = .failed
                restoreSystem(reason: "Auto Boost needs a valid temperature")
                return
            }
            updateSmartTargets(
                temperature: temperature,
                confirmation: "Auto Boost · \(state.profile.displayName)",
                confirmedProfile: state.profile
            )
        }
    }

    func applyManualTargets(_ targets: [FanTarget]) {
        guard state.selectedMode == .manual, state.helperReady else {
            state.applyFeedback = .failed
            state.status = "Enable the helper before using Manual control"
            publish()
            return
        }

        let capabilities = Dictionary(uniqueKeysWithValues: state.capabilities.map { ($0.index, $0) })
        let safeTargets = targets.compactMap { target -> FanTarget? in
            guard target.rpm.isFinite, let fan = capabilities[target.index] else { return nil }
            return FanTarget(index: target.index, rpm: min(fan.maximumRPM, max(fan.minimumRPM, target.rpm)))
        }
        guard safeTargets.count == state.capabilities.count else {
            state.applyFeedback = .failed
            state.status = "Manual targets are incomplete"
            publish()
            return
        }

        state.manualTargets = safeTargets
        state.applyFeedback = .working
        state.status = "Applying Manual targets…"
        captureSystemBaselineIfNeeded()
        publish()
        sendTargets(safeTargets, confirmedMode: .manual, confirmation: "Manual")
    }

    func restoreForSleep() {
        state.selectedMode = .system
        state.applyFeedback = .failed
        restoreSystem(reason: "System control restored for sleep/wake")
    }

    func userRestoreSystem() {
        state.selectedMode = .system
        state.applyFeedback = .working
        state.status = "Applying System…"
        publish()
        applySystemSelection()
    }

    func restoreBeforeTermination() {
        guard state.activeMode != .system else { return }
        remoteProxy()?.restoreSystem { _ in }
        heartbeatTimer?.invalidate()
    }

    private func refreshRegistrationState() {
        state.helperRegistration = helperIsInstalled ? "Installed" : "Not enabled"
        publish()
    }

    private var helperIsInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.installedHelperPath)
            && FileManager.default.fileExists(atPath: Self.installedPlistPath)
    }

    private func prepareHelperInstallation() throws -> (appleScript: String, temporaryPlist: URL) {
        guard let appExecutable = Bundle.main.executableURL,
              let codeHash = Self.codeHash(for: appExecutable)
        else {
            throw NSError(domain: "ThermoBar.FanControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to identify this MyBar build"])
        }
        let bundledHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/local.thermobar.fanhelper")
        guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else {
            throw NSError(domain: "ThermoBar.FanControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bundled fan helper is missing"])
        }

        let plist: [String: Any] = [
            "Label": FanHelperConstants.machServiceName,
            "Program": Self.installedHelperPath,
            "ProgramArguments": [
                Self.installedHelperPath,
                "--client-executable=\(appExecutable.resolvingSymlinksInPath().path)",
                "--client-cdhash=\(codeHash)",
            ],
            "MachServices": [FanHelperConstants.machServiceName: true],
            "KeepAlive": ["Crashed": true],
            "ProcessType": "Interactive",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let temporaryPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("local.thermobar.fanhelper-\(UUID().uuidString).plist")
        try plistData.write(to: temporaryPlist, options: .atomic)

        let commands = [
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(Self.shellQuote(bundledHelper.path)) \(Self.shellQuote(Self.installedHelperPath))",
            "/usr/bin/install -o root -g wheel -m 644 \(Self.shellQuote(temporaryPlist.path)) \(Self.shellQuote(Self.installedPlistPath))",
            "/bin/launchctl bootout system/\(FanHelperConstants.machServiceName) >/dev/null 2>&1 || /usr/bin/true",
            "/bin/launchctl bootstrap system \(Self.shellQuote(Self.installedPlistPath))",
            "/bin/launchctl enable system/\(FanHelperConstants.machServiceName)",
        ]
        let shellCommand = commands.joined(separator: "; ")
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ("do shell script \"\(escaped)\" with administrator privileges", temporaryPlist)
    }

    private static func codeHash(for executable: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              let data = info[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func connect() {
        connection?.invalidate()
        let connection = NSXPCConnection(machServiceName: FanHelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ThermoBarFanHelperProtocol.self)
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.controllerUnavailable("Helper interrupted; macOS fallback is active") }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.controllerUnavailable("Helper disconnected; macOS fallback is active") }
        }
        connection.resume()
        self.connection = connection

        remoteProxy()?.status { [weak self] data in
            guard let status = try? JSONDecoder().decode(FanHelperStatus.self, from: data) else {
                DispatchQueue.main.async { self?.controllerUnavailable("Invalid helper response") }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.helperReady = status.isReady
                self.state.helperFeedback = status.isReady ? .confirmed : .failed
                self.state.capabilities = status.fans
                self.state.targets = status.activeTargets
                self.state.activeMode = status.activeTargets.isEmpty ? .system : self.state.activeMode
                self.state.status = status.isReady ? "Helper enabled and confirmed" : status.message
                self.publish()
            }
        }
    }

    private func updateSmartTargets(
        temperature: Double,
        confirmation: String? = nil,
        confirmedProfile: FanResponseProfile? = nil
    ) {
        let curveProfile = confirmedProfile ?? state.activeProfile ?? state.profile
        let demand = SmartFanCurve.demand(temperature: temperature, profile: curveProfile)
        if demand == 0 {
            enterSmartStandby(confirmation: confirmation, confirmedProfile: confirmedProfile)
            return
        }

        let desired = SmartFanCurve.targets(capabilities: state.capabilities, demand: demand)
        let current = Dictionary(uniqueKeysWithValues: state.targets.map { ($0.index, $0.rpm) })
        let safeTargets = desired.map { target in
            // While Smart mode owns the fans, never lower a manual target. It
            // releases the fans entirely to macOS after the system cools.
            FanTarget(index: target.index, rpm: max(target.rpm, current[target.index] ?? target.rpm))
        }
        let changed = safeTargets.contains { abs($0.rpm - (current[$0.index] ?? -10_000)) >= 100 }
        if changed {
            captureSystemBaselineIfNeeded()
            sendTargets(
                safeTargets,
                confirmedMode: confirmation == nil ? nil : .smart,
                confirmedProfile: confirmedProfile,
                confirmation: confirmation
            )
        } else if let confirmation {
            confirmApplied(mode: .smart, profile: confirmedProfile, name: confirmation)
        }
    }

    private func sendTargets(
        _ targets: [FanTarget],
        confirmedMode: FanControlMode? = nil,
        confirmedProfile: FanResponseProfile? = nil,
        confirmation: String? = nil
    ) {
        guard !commandInFlight else { return }
        guard !targets.isEmpty else {
            state.applyFeedback = .failed
            state.status = "No controllable fans were reported by the helper"
            publish()
            return
        }
        guard let data = try? JSONEncoder().encode(FanTargetRequest(targets: targets)),
              let proxy = remoteProxy()
        else {
            controllerUnavailable("Unable to contact helper; display is still monitoring")
            return
        }

        commandInFlight = true
        proxy.applyTargets(data) { [weak self] responseData in
            let response = try? JSONDecoder().decode(FanCommandResponse.self, from: responseData)
            DispatchQueue.main.async {
                guard let self else { return }
                self.commandInFlight = false
                guard let response, response.success else {
                    self.controllerUnavailable(response?.message ?? "Fan command failed; macOS fallback is active")
                    return
                }
                self.state.targets = response.appliedTargets
                if let confirmedMode, let confirmation {
                    self.confirmApplied(mode: confirmedMode, profile: confirmedProfile, name: confirmation)
                } else if self.state.applyFeedback == .confirmed,
                          self.state.activeMode == .smart,
                          let profile = self.state.activeProfile {
                    self.state.status = "✓ Auto Boost · \(profile.displayName) confirmed and active"
                } else {
                    self.state.status = response.message
                }
                self.startHeartbeat()
                self.publish()
            }
        }
    }

    private func restoreSystem(reason: String) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        state.activeMode = .system
        state.activeProfile = nil
        state.systemBaselineRPM = nil
        if state.selectedMode != .system { state.applyFeedback = .failed }
        state.targets = []
        state.status = reason
        publish()

        remoteProxy()?.restoreSystem { [weak self] data in
            let response = try? JSONDecoder().decode(FanCommandResponse.self, from: data)
            guard response?.success == false else { return }
            DispatchQueue.main.async { self?.controllerUnavailable(response?.message ?? "System restore failed") }
        }
    }

    private func enterSmartStandby(
        confirmation: String? = nil,
        confirmedProfile: FanResponseProfile? = nil
    ) {
        let shouldRestore = !state.targets.isEmpty
        if !shouldRestore, state.activeMode == .smart, confirmation == nil { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        state.targets = []
        state.systemBaselineRPM = nil
        if shouldRestore {
            remoteProxy()?.restoreSystem { [weak self] data in
                let response = try? JSONDecoder().decode(FanCommandResponse.self, from: data)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if response?.success == true, let confirmation {
                        self.confirmApplied(mode: .smart, profile: confirmedProfile, name: confirmation + " · standby")
                    } else if response?.success == false {
                        self.controllerUnavailable(response?.message ?? "Unable to enter Auto Boost standby")
                    }
                }
            }
        } else if let confirmation {
            confirmApplied(mode: .smart, profile: confirmedProfile, name: confirmation + " · standby")
        } else {
            state.activeMode = .smart
            state.status = "Auto Boost standby below 50°C; macOS controls the fans"
            publish()
        }
    }

    private func applySystemSelection() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        guard state.helperReady, let proxy = remoteProxy() else {
            confirmApplied(mode: .system, profile: nil, name: "System")
            return
        }
        proxy.restoreSystem { [weak self] data in
            let response = try? JSONDecoder().decode(FanCommandResponse.self, from: data)
            DispatchQueue.main.async {
                guard let self else { return }
                if response?.success == true {
                    self.state.targets = []
                    self.state.systemBaselineRPM = nil
                    self.confirmApplied(mode: .system, profile: nil, name: "System")
                } else {
                    self.controllerUnavailable(response?.message ?? "System restore failed")
                }
            }
        }
    }

    private func confirmApplied(mode: FanControlMode, profile: FanResponseProfile?, name: String) {
        state.activeMode = mode
        state.activeProfile = profile
        state.applyFeedback = .confirmed
        state.status = "✓ \(name) confirmed and active"
        publish()
    }

    private var selectedSettingName: String {
        state.selectedMode == .smart
            ? "Auto Boost · \(state.profile.displayName)"
            : state.selectedMode.displayName
    }

    private func initializeManualTargetsIfNeeded() {
        guard state.manualTargets.isEmpty else { return }
        state.manualTargets = state.capabilities.map { capability in
            let actual = capability.index < state.actualRPM.count ? state.actualRPM[capability.index] : nil
            let initial = min(capability.maximumRPM, max(capability.minimumRPM, actual ?? capability.minimumRPM))
            return FanTarget(index: capability.index, rpm: initial)
        }
    }

    private func captureSystemBaselineIfNeeded() {
        guard state.systemBaselineRPM == nil, let readings = latestSnapshot?.fanRPM else { return }
        let available = readings.compactMap { $0 }
        guard !available.isEmpty else { return }
        state.systemBaselineRPM = available.reduce(0, +) / Double(available.count)
    }

    private func markSelectionPendingIfNeeded() {
        let matchesMode = state.selectedMode == state.activeMode
        let matchesProfile = state.selectedMode != .smart || state.profile == state.activeProfile
        if matchesMode && matchesProfile {
            state.applyFeedback = .confirmed
            state.status = "✓ \(selectedSettingName) confirmed and active"
        } else {
            state.applyFeedback = .idle
            state.status = "Selected \(selectedSettingName) — press Apply to confirm"
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.state.targets.isEmpty else { return }
            self.remoteProxy()?.heartbeat { ok in
                guard !ok else { return }
                DispatchQueue.main.async { self.controllerUnavailable("Safety heartbeat failed; macOS fallback is active") }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func remoteProxy() -> ThermoBarFanHelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.controllerUnavailable("Helper error: \(error.localizedDescription)") }
        } as? ThermoBarFanHelperProtocol
    }

    private func controllerUnavailable(_ message: String) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        commandInFlight = false
        state.helperReady = false
        state.helperFeedback = .failed
        state.applyFeedback = .failed
        state.activeMode = .system
        state.activeProfile = nil
        state.systemBaselineRPM = nil
        state.targets = []
        state.status = message
        publish()
    }

    private func publish() {
        onStateChange?(state)
    }
}
