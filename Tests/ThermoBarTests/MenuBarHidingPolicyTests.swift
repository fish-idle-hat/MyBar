import Foundation
import MenuBarControlProtocol
import XCTest
@testable import ThermoBar

final class MenuBarHidingPolicyTests: XCTestCase {
    func testUnverifiedPrivateAPIActivationStaysDisabled() {
        XCTAssertFalse(MenuBarHidingPolicy.experimentalActivationAllowed)
    }
    func testOnlyExplicitOwnersAreRemovedAndSystemAndThermoBarPreserved() throws {
        let running: Set<String> = ["com.example.hidden", "com.example.keep", "com.apple.controlcenter", "local.thermobar.app"]
        let allowed = try XCTUnwrap(MenuBarHidingPolicy.allowedBundleIDs(hidden: ["com.example.hidden"],
                                              running: running, visible: ["com.example.extraAgent"]))
        XCTAssertFalse(allowed.contains("com.example.hidden"))
        XCTAssertTrue(Set(allowed).isSuperset(of: ["com.example.keep", "com.apple.controlcenter", "local.thermobar.app", "com.example.extraAgent"]))
        XCTAssertTrue(allowed.contains("com.apple.Siri"), "Essential system owners stay allowed even if workspace discovery omits them")
    }

    func testRejectsSystemOwnUnknownAndEmptyHideSets() {
        for hidden: Set<String> in [[], ["com.apple.Spotlight"], ["local.thermobar.app"], ["unknown"], ["com.example.notRunning"], ["bad.\nidentifier"]] {
            XCTAssertNil(MenuBarHidingPolicy.allowedBundleIDs(hidden: hidden,
                running: ["com.apple.Spotlight", "local.thermobar.app", "unknown", "bad.\nidentifier"], visible: []))
        }
    }

    func testProtocolRoundTripAndNoImplicitHideDefaults() throws {
        let request = MenuBarHelperRequest(id: "test", action: .heartbeat)
        let decoded = try JSONDecoder().decode(MenuBarHelperRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.action, .heartbeat)
        XCTAssertTrue(decoded.hiddenBundleIDs.isEmpty)
        let response = MenuBarHelperResponse(id: "test", state: .applied, message: "Awaiting visibility verification")
        XCTAssertEqual(try JSONDecoder().decode(MenuBarHelperResponse.self, from: JSONEncoder().encode(response)).state, .applied)
    }

    @MainActor
    func testMissingHelperFailsWithoutAffectingMonitoringProcess() {
        let client = MenuBarHelperClient(helperURL: URL(fileURLWithPath: "/private/tmp/does-not-exist-thermobar-helper-\(UUID().uuidString)"))
        var failed = false
        client.hide(bundleIDs: ["com.example.app"], visibleBundleIDs: []) {
            if case .failure = $0 { failed = true }
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(client.available)
    }

    @MainActor
    func testChildImmediateExitIsContainedAndReportedOnce() {
        let client = MenuBarHelperClient(helperURL: URL(fileURLWithPath: "/usr/bin/false"))
        let finished = expectation(description: "Helper failure returned to live parent")
        var callbacks = 0
        client.hide(bundleIDs: ["com.example.app"], visibleBundleIDs: []) { result in
            callbacks += 1
            if case .success = result { XCTFail("Failed child must not count as applied") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        client.stop()
        XCTAssertEqual(callbacks, 1)
    }

    @MainActor
    func testSmallRequestAndResponseArriveWithoutClosingThePipe() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/debug/ThermoBarMenuHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("Helper unavailable in custom build directory") }
        let client = MenuBarHelperClient(helperURL: helper)
        let response = expectation(description: "Small JSON response arrives while stdin remains open")
        // This request must be rejected before any assertion is activated.
        client.hide(bundleIDs: ["com.apple.MenuBarAgent"], visibleBundleIDs: []) { result in
            switch result {
            case .success: XCTFail("Protected owners must never be hidden")
            case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("Rejected unsafe"), error.localizedDescription)
            }
            response.fulfill()
        }
        wait(for: [response], timeout: 3)
        client.stop()
    }
}
