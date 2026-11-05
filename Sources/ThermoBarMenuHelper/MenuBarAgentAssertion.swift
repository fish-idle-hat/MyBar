import Foundation

// Runtime bridge informed by MenuBarHider (MIT); see THIRD_PARTY_NOTICES.md.
// Nothing in the monitoring process imports or loads this private framework.
@objc private protocol MenuAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(configuration: AnyObject, completion: @escaping (NSError?) -> Void)
    func invalidate()
}

final class MenuBarAgentAssertion {
    private let assertionType: NSObject.Type?
    private let configurationType: NSObject.Type?
    private let initializer = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private var pending: MenuAssertion?
    private var active: MenuAssertion?
    private var generation = 0

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW)
        let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type
        let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type
        if handle != nil,
           assertion?.instancesRespond(to: #selector(MenuAssertion.activate(configuration:completion:))) == true,
           assertion?.instancesRespond(to: #selector(MenuAssertion.invalidate)) == true,
           configuration?.instancesRespond(to: initializer) == true {
            assertionType = assertion
            configurationType = configuration
        } else {
            assertionType = nil
            configurationType = nil
        }
    }

    var available: Bool { assertionType != nil && configurationType != nil }

    func activate(allowed: [String], completion: @escaping (String?) -> Void) {
        release()
        guard let assertionType, let configurationType,
              let allocated = (configurationType as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let configuration = allocated.perform(initializer,
                    with: (0..<64).map { NSNumber(value: $0) } as NSArray,
                    with: allowed as NSArray)?.takeRetainedValue() else {
            completion("MenuBarAgent API unavailable or changed."); return
        }
        let token = generation
        let assertion = unsafeBitCast(assertionType.init(), to: MenuAssertion.self)
        pending = assertion
        assertion.activate(configuration: configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { assertion.invalidate(); return }
                self.pending = nil
                if let error {
                    assertion.invalidate()
                    completion("MenuBarAgent refused hiding: \(error.localizedDescription)")
                } else {
                    self.active = assertion
                    completion(nil)
                }
            }
        }
    }

    func release() {
        generation += 1
        pending?.invalidate()
        pending = nil
        active?.invalidate()
        active = nil
    }
}
