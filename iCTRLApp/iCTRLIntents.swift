import AppIntents
import Foundation

@available(iOS 16.0, *)
struct CheckiCTRLReadinessIntent: AppIntent {
    static var title: LocalizedStringResource = "Check iCTRL Readiness"
    static var description = IntentDescription("Check Developer Disk Image and actual local server response; returns a JSON status string.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await StartupCoordinator.shared.status())
    }
}

@available(iOS 16.0, *)
struct PrepareiCTRLIntent: AppIntent {
    static var title: LocalizedStringResource = "Prepare iCTRL"
    static var description = IntentDescription("Mount a cached Developer Disk Image using an already connected LocalDevVPN, then start Runner and verify its local API. Expected failures return JSON ok:false so a Shortcut can restore its VPN.")
    static var openAppWhenRun = true
    @Parameter(title: "Mount If Needed", default: true) var mountIfNeeded: Bool
    @Parameter(title: "Keep Awake While Foreground", default: true) var keepAwake: Bool
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: await StartupCoordinator.shared.prepare(mountIfNeeded: mountIfNeeded, keepAwake: keepAwake))
    }
}

@available(iOS 16.0, *)
struct iCTRLShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareiCTRLIntent(), phrases: ["Prepare \(.applicationName)"], shortTitle: "Prepare iCTRL", systemImageName: "play.circle")
        AppShortcut(intent: CheckiCTRLReadinessIntent(), phrases: ["Check \(.applicationName)"], shortTitle: "Check iCTRL", systemImageName: "checkmark.circle")
    }
}

@available(iOS 16.0, *)
struct RecordiCTRLRenewalCompletionIntent: AppIntent {
    static var title: LocalizedStringResource = "Record iCTRL Renewal Progress"
    static var description = IntentDescription("Record a local Shortcut attempt UUID and completion time only. This does not certify renewal; profile expiry dates must still be checked.")
    static var openAppWhenRun = true
    @Parameter(title: "Attempt ID") var attemptID: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let receipt = RenewalGateStore.permitsReceipt(token: attemptID)
            ? RenewalReceiptStore.record(attemptID: attemptID) : nil
        let result: [String: JSONValue] = ["ok": .bool(receipt != nil), "renewal_receipt": receipt.map(JSONValue.object) ?? .null]
        return .result(value: String(decoding: (try? JSONEncoder().encode(result)) ?? Data("{}".utf8), as: UTF8.self))
    }
}
