import XCTest
import ObjectiveC.runtime

/// Disable XCTest's implicit cancel/default alert clicks. Never claim this blocks notifications.
/// Appium WebDriverAgent uses the same one-method override. Fail closed if SDK changes.
enum NativeInterruptionGuard {
    private static let configured: Bool = {
        let selector = NSSelectorFromString("doesNotHandleUIInterruptions")
        guard let method = class_getInstanceMethod(XCUIApplication.self, selector),
              method_getNumberOfArguments(method) == 2,
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding).hasPrefix("B") || String(cString: encoding).hasPrefix("c") else { return false }
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }()
    static var available: Bool { configured }
}
