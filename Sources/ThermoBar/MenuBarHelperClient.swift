import AppKit
import MenuBarControlProtocol

/// Only JSON crosses this boundary. Private Objective-C messages execute in the disposable child.
final class MenuBarHelperClient {
    var onUnexpectedExit: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var heartbeat: Timer?
    private var timeout: DispatchWorkItem?
    private var pending: (id: String, completion: (Result<Void, Error>) -> Void)?
    private let ioQueue = DispatchQueue(label: "ThermoBar.menu-helper-io", qos: .utility)
    private var session = UUID()
    private var buffer = Data()
    private let helperURL: URL

    init(helperURL: URL = MenuBarHelperClient.bundledURL) { self.helperURL = helperURL }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var bundledURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/local.thermobar.menuhelper")
    }
    var available: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }
    func owns(processID: pid_t) -> Bool { process?.processIdentifier == processID }

    func crashForIsolationCheck() {
        guard CommandLine.arguments.contains("--organizer-self-test"), let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    func hide(bundleIDs: [String], visibleBundleIDs: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        guard available else { completion(.failure(Failure(message: "Menu bar helper is missing. Rebuild/reinstall MyBar."))); return }
        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        task.executableURL = helperURL
        task.arguments = ["--parent-pid", String(getpid())]
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        let token = UUID()
        session = token
        let id = UUID().uuidString
        pending = (id, completion)
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            // read(upToCount:) waits for that size or EOF on a pipe. Messages are
            // intentionally small and the connection stays open for heartbeats.
            let chunk = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.session == token else { return }
                if chunk.isEmpty { self.disconnected("Menu bar helper disconnected; originals restored."); return }
                self.buffer.append(chunk)
                guard self.buffer.count <= 65_536 else { self.disconnected("Invalid helper response; originals restored."); return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: newline)
                    self.buffer.removeSubrange(...newline)
                    guard let response = try? JSONDecoder().decode(MenuBarHelperResponse.self, from: line) else {
                        self.disconnected("Invalid helper response; originals restored."); return
                    }
                    if response.state == .revealed {
                        self.disconnected(response.message); return
                    }
                    if response.state == .error {
                        self.disconnected(response.message); return
                    }
                    if response.state == .applied, response.id == self.pending?.id {
                        let callback = self.pending?.completion
                        self.pending = nil
                        self.timeout?.cancel()
                        self.timeout = nil
                        callback?(.success(()))
                    }
                }
            }
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.session == token else { return }
                self.disconnected("Menu bar helper exited; originals restored.")
            }
        }
        do {
            try task.run()
            // Do not keep a second copy of the child's pipe endpoints in the parent.
            try? stdin.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            send(MenuBarHelperRequest(id: id, action: .hide, hiddenBundleIDs: bundleIDs, visibleBundleIDs: visibleBundleIDs))
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.send(MenuBarHelperRequest(id: "", action: .heartbeat))
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
            let expiry = DispatchWorkItem { [weak self] in
                guard let self, self.session == token else { return }
                self.disconnected("Menu bar helper timed out; originals restored.")
            }
            timeout = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: expiry)
        } catch { disconnected("Cannot start menu bar helper: \(error.localizedDescription)") }
    }

    func stop() {
        session = UUID() // Late replies/termination callbacks from this child must not affect a new operation.
        heartbeat?.invalidate()
        heartbeat = nil
        timeout?.cancel()
        timeout = nil
        let callback = pending?.completion
        pending = nil
        output?.readabilityHandler = nil
        // A callback already in flight owns its handle. Let ARC close it after
        // that read returns, rather than explicitly closing underneath the read.
        output = nil
        let oldInput = input
        input = nil
        let oldProcess = process
        process = nil
        ioQueue.async { try? oldInput?.close() } // EOF releases the assertion in the helper.
        if oldProcess?.isRunning == true {
            oldProcess?.terminate() // SIGTERM also invalidates before exiting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let oldProcess, oldProcess.isRunning { kill(oldProcess.processIdentifier, SIGKILL) }
            }
        }
        callback?(.failure(Failure(message: "Menu bar operation cancelled; originals restored.")))
    }

    private func send(_ request: MenuBarHelperRequest) {
        guard let handle = input, let data = try? JSONEncoder().encode(request) else { return }
        let token = session
        ioQueue.async { [weak self] in
            do { try handle.write(contentsOf: data + Data([10])) }
            catch {
                DispatchQueue.main.async {
                    guard let self, self.session == token else { return }
                    self.disconnected("Menu bar helper connection failed; originals restored.")
                }
            }
        }
    }

    private func disconnected(_ message: String) {
        let callback = pending?.completion
        pending = nil
        stop()
        callback?(.failure(Failure(message: message)))
        onUnexpectedExit?(message)
    }

    deinit { stop() }
}
