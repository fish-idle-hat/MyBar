import Foundation
import FanControlProtocol

final class FanHelperService: NSObject, ThermoBarFanHelperProtocol {
    private let queue = DispatchQueue(label: "local.thermobar.fanhelper.smc")
    private var writer: SMCWriter?
    private var fans: [FanCapability] = []
    private var activeTargets: [FanTarget] = []
    private var lastHeartbeat = Date.distantPast
    private var initializationError: String?
    private var timer: DispatchSourceTimer?

    override init() {
        super.init()
        queue.sync {
            do {
                guard geteuid() == 0 else { throw SMCWriter.Error.invalidTarget("Helper is not running as root") }
                let writer = try SMCWriter()
                let fans = try writer.capabilities()
                writer.restoreSystem(capabilities: fans)
                self.writer = writer
                self.fans = fans
            } catch {
                initializationError = String(describing: error)
            }
        }
        startWatchdog()
    }

    func status(withReply reply: @escaping (Data) -> Void) {
        queue.async {
            let ready = self.writer != nil && !self.fans.isEmpty
            let message = self.initializationError ?? (ready ? "Helper ready" : "Fan control unavailable")
            reply(Self.encode(FanHelperStatus(
                version: FanHelperConstants.version,
                isReady: ready,
                fans: self.fans,
                activeTargets: self.activeTargets,
                message: message
            )))
        }
    }

    func applyTargets(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async {
            guard let writer = self.writer else {
                reply(Self.encode(FanCommandResponse(success: false, message: self.initializationError ?? "Helper unavailable")))
                return
            }
            do {
                let command = try JSONDecoder().decode(FanTargetRequest.self, from: request)
                let applied = try writer.apply(command.targets, capabilities: self.fans)
                self.activeTargets = applied
                self.lastHeartbeat = Date()
                reply(Self.encode(FanCommandResponse(success: true, message: "Manual fan control active", appliedTargets: applied)))
            } catch {
                self.restoreLocked()
                reply(Self.encode(FanCommandResponse(success: false, message: String(describing: error))))
            }
        }
    }

    func restoreSystem(withReply reply: @escaping (Data) -> Void) {
        queue.async {
            self.restoreLocked()
            reply(Self.encode(FanCommandResponse(success: true, message: "System fan control restored")))
        }
    }

    func heartbeat(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            guard !self.activeTargets.isEmpty else { reply(false); return }
            self.lastHeartbeat = Date()
            reply(true)
        }
    }

    func clientDisconnected() {
        queue.async { self.restoreLocked() }
    }

    func restoreSynchronously() {
        queue.sync { restoreLocked() }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, !self.activeTargets.isEmpty else { return }
            if Date().timeIntervalSince(self.lastHeartbeat) > FanHelperConstants.watchdogSeconds {
                self.restoreLocked()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func restoreLocked() {
        writer?.restoreSystem(capabilities: fans)
        activeTargets = []
        lastHeartbeat = .distantPast
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
