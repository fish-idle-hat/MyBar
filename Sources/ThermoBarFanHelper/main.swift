import Foundation
import FanControlProtocol
import Security

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = FanHelperService()
    private let expectedClientExecutable = CommandLine.arguments
        .first { $0.hasPrefix("--client-executable=") }?
        .replacingOccurrences(of: "--client-executable=", with: "")
    private let expectedClientCodeHash = CommandLine.arguments
        .first { $0.hasPrefix("--client-cdhash=") }?
        .replacingOccurrences(of: "--client-cdhash=", with: "")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAuthorizedClient(connection.processIdentifier) else { return false }

        connection.exportedInterface = NSXPCInterface(with: ThermoBarFanHelperProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak service] in service?.clientDisconnected() }
        connection.resume()
        return true
    }

    private func isAuthorizedClient(_ pid: pid_t) -> Bool {
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode
        else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return false }

        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == "local.thermobar.app",
              let executableURL = info[kSecCodeInfoMainExecutable as String] as? URL,
              let codeHash = info[kSecCodeInfoUnique as String] as? Data,
              let expectedClientExecutable,
              let expectedClientCodeHash
        else { return false }

        let actualHash = codeHash.map { String(format: "%02x", $0) }.joined()
        let expectedURL = URL(fileURLWithPath: expectedClientExecutable).resolvingSymlinksInPath()
        return executableURL.resolvingSymlinksInPath() == expectedURL && actualHash == expectedClientCodeHash
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: FanHelperConstants.machServiceName)
listener.delegate = delegate

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        delegate.service.restoreSynchronously()
        exit(EXIT_SUCCESS)
    }
    source.resume()
    signalSources.append(source)
}

listener.resume()
dispatchMain()
