// One-time, explicitly approved setup. Default: read-only dry run.
// swift scripts/configure-four-finger-mapping.swift [--apply|--restore backup.plist]
// Uses the same native preference scopes as SwipeSwitcher; see THIRD_PARTY_NOTICES.
import Foundation
import CoreFoundation

struct Snapshot: Codable {
    let version: Int
    let created: Date
    let fourFingerValues: [Int?]
    let threeFingerValues: [Int?]
}
struct Scope {
    let domain: CFString
    let host: CFString
    let four: String
    let three: String
}
let deviceDomains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
let scopes = deviceDomains.map {
    Scope(domain: $0 as CFString, host: kCFPreferencesAnyHost,
          four: "TrackpadFourFingerHorizSwipeGesture", three: "TrackpadThreeFingerHorizSwipeGesture")
} + [Scope(domain: kCFPreferencesAnyApplication, host: kCFPreferencesCurrentHost,
           four: "com.apple.trackpad.fourFingerHorizSwipeGesture", three: "com.apple.trackpad.threeFingerHorizSwipeGesture")]
let reloadPath = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
func failure(_ message: String) -> NSError { NSError(domain: "MyBarTrackpadSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
func read(_ key: String, _ scope: Scope) throws -> Int? {
    guard CFPreferencesSynchronize(scope.domain, kCFPreferencesCurrentUser, scope.host) else { throw failure("Preference refresh failed") }
    guard let value = CFPreferencesCopyValue(key as CFString, scope.domain, kCFPreferencesCurrentUser, scope.host) else { return nil }
    guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
          (0...2).contains(number.intValue), number.doubleValue == Double(number.intValue) else { throw failure("Unsupported gesture value; no changes made") }
    return number.intValue
}
func snapshot() throws -> Snapshot {
    // A current-host override in a device domain would defeat the narrow three-scope edit.
    for scope in scopes.prefix(2) {
        let override = Scope(domain: scope.domain, host: kCFPreferencesCurrentHost, four: scope.four, three: scope.three)
        guard try read(scope.four, override) == nil else { throw failure("Device host override present; requires separate review") }
    }
    return try Snapshot(version: 1, created: Date(), fourFingerValues: scopes.map { try read($0.four, $0) },
                        threeFingerValues: scopes.map { try read($0.three, $0) })
}
func writeFour(_ values: [Int?]) throws {
    guard values.count == scopes.count else { throw failure("Invalid snapshot size") }
    for (scope, value) in zip(scopes, values) {
        CFPreferencesSetValue(scope.four as CFString, value.map { NSNumber(value: $0) }, scope.domain, kCFPreferencesCurrentUser, scope.host)
        guard CFPreferencesSynchronize(scope.domain, kCFPreferencesCurrentUser, scope.host) else { throw failure("Preference save failed") }
    }
}
func reload() throws {
    guard FileManager.default.isExecutableFile(atPath: reloadPath) else { throw failure("Native settings reloader unavailable") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: reloadPath); process.arguments = ["-u"]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw failure("Native settings reload failed") }
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    let before = try snapshot()
    for (index, scope) in scopes.enumerated() {
        print("\(scope.domain): three=\(before.threeFingerValues[index].map(String.init) ?? "unset") four=\(before.fourFingerValues[index].map(String.init) ?? "unset")")
    }
    if args.isEmpty {
        print("DRY RUN: no changes. Apply requires --apply and a new backup path; restore requires --restore and that backup.")
    } else {
        guard args.count == 2, ["--apply", "--restore"].contains(args[0]) else { throw failure("Usage: [--apply|--restore backup.plist]") }
        guard FileManager.default.isExecutableFile(atPath: reloadPath) else { throw failure("Native settings reloader unavailable; no changes made") }
        let backupURL = URL(fileURLWithPath: args[1])
        let target: [Int?]
        if args[0] == "--apply" {
            guard before.threeFingerValues.allSatisfy({ $0 == 2 }) else { throw failure("Three-finger desktop switching is not configured in all scopes; no changes made") }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
            try encoder.encode(before).write(to: backupURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            target = [0, 0, 0]
        } else {
            let size = try backupURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 && size < 8192 else { throw failure("Invalid backup size") }
            let saved = try PropertyListDecoder().decode(Snapshot.self, from: Data(contentsOf: backupURL))
            guard saved.version == 1, saved.fourFingerValues.count == 3,
                  saved.threeFingerValues.count == 3,
                  saved.fourFingerValues.allSatisfy({ $0 == nil || (0...2).contains($0!) }),
                  before.fourFingerValues.allSatisfy({ $0 == 0 }) else { throw failure("Backup invalid or settings changed since setup; no changes made") }
            target = saved.fourFingerValues
        }
        do {
            try writeFour(target); try reload()
            let after = try snapshot()
            guard after.fourFingerValues == target, after.threeFingerValues == before.threeFingerValues else { throw failure("Readback mismatch") }
        } catch {
            let original = error
            do { try writeFour(before.fourFingerValues); try reload(); print("Rolled back original four-finger values.") }
            catch { print("Rollback needs attention: \(error.localizedDescription). Backup: \(backupURL.path)") }
            throw original
        }
        print("Verified \(args[0]); three-finger values unchanged. Backup: \(backupURL.path)")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr); exit(1)
}
