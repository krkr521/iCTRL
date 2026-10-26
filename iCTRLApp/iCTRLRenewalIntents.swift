import AppIntents
import Foundation

@MainActor
private enum RenewalIntentSupport {
    static func json(_ value: [String: JSONValue]) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    static func freshProfiles() async -> RenewalProfileSnapshot? {
        // Caller has already connected LocalDevVPN and run Prepare(true).
        // Mounted-DDI verification can then use either VPN with local URLs.
        let result = await StartupCoordinator.shared.prepare(mountIfNeeded: false)
        guard let raw = result.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: JSONValue].self, from: raw),
              value["ok"]?.boolValue == true, value["server_running"]?.boolValue == true,
              value["runner_profile_expiry_verified"]?.boolValue == true,
              let companionText = value["companion_profile_expires_at"]?.stringValue,
              let runnerText = value["runner_profile_expires_at"]?.stringValue,
              let companion = ISO8601DateFormatter().date(from: companionText),
              let runner = ISO8601DateFormatter().date(from: runnerText),
              let companionID = value["companion_bundle_id"]?.stringValue,
              let runnerID = value["runner_bundle_id"]?.stringValue else { return nil }
        return RenewalProfileSnapshot(companionExpiry: companion, runnerExpiry: runner,
            companionBundleID: companionID, runnerBundleID: runnerID,
            companionTeam: value["companion_team_identifier"]?.stringValue,
            runnerTeam: value["runner_team_identifier"]?.stringValue,
            observedAt: Date(), runnerVerified: true)
    }

    static func receipt() -> RenewalGateReceipt? {
        guard let fields = RenewalReceiptStore.currentJSON().objectValue,
              let id = fields["attempt_id"]?.stringValue,
              let time = fields["completed_at"]?.stringValue,
              let date = ISO8601DateFormatter().date(from: time) else { return nil }
        return RenewalGateReceipt(attemptID: id, completedAt: date)
    }
}

@available(iOS 16.0, *)
struct PlaniCTRLRenewalIntent: AppIntent {
    static var title: LocalizedStringResource = "Plan iCTRL Renewal"
    static var description = IntentDescription("Phone-local five-calendar-day gate. Reserve If Due claims recovery state before any VPN switch. False only reads recovery state and never brings iCTRL forward.")
    static var openAppWhenRun = false
    @Parameter(title: "Reserve If Due", default: false) var reserveIfDue: Bool
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: RenewalIntentSupport.json(RenewalGateStore.plan(reserveIfDue: reserveIfDue)))
    }
}

@available(iOS 16.0, *)
struct BeginiCTRLRenewalIntent: AppIntent {
    static var title: LocalizedStringResource = "Begin iCTRL Renewal"
    static var description = IntentDescription("After LocalDevVPN and Prepare iCTRL with mounting enabled, read fresh actual profile dates and authorize one refresh UUID only when due. Bootstrap expiry minus two days never creates a last-success record.")
    static var openAppWhenRun = true
    @Parameter(title: "Preparation Token") var prepareToken: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let start = Date(), calendar = Calendar.current
        let claim = RenewalGateStore.transact(now: start, calendar: calendar) { $0.claimBefore(token: prepareToken, now: start, calendar: calendar) }
        guard claim["ok"]?.boolValue == true else { return .result(value: RenewalIntentSupport.json(claim)) }
        let snapshot = await RenewalIntentSupport.freshProfiles()
        let now = Date()
        let result = RenewalGateStore.transact(now: now, calendar: calendar) { $0.begin(token: prepareToken, snapshot: snapshot, now: now, calendar: calendar) }
        return .result(value: RenewalIntentSupport.json(result))
    }
}

@available(iOS 16.0, *)
struct FinalizeiCTRLRenewalIntent: AppIntent {
    static var title: LocalizedStringResource = "Finalize iCTRL Renewal"
    static var description = IntentDescription("Commit last success only for the current attempt's post-refresh receipt and fresh matching profiles that both extended and each have at least six days left. This does not read SideStore's sandbox profile.")
    static var openAppWhenRun = true
    @Parameter(title: "Attempt ID") var attemptID: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let start = Date(), calendar = Calendar.current
        let claim = RenewalGateStore.transact(now: start, calendar: calendar) { $0.claimVerification(token: attemptID, now: start, calendar: calendar) }
        guard claim["ok"]?.boolValue == true else { return .result(value: RenewalIntentSupport.json(claim)) }
        let snapshot = await RenewalIntentSupport.freshProfiles()
        let receipt = RenewalIntentSupport.receipt(), now = Date()
        let result = RenewalGateStore.transact(now: now, calendar: calendar) { $0.finalize(token: attemptID, snapshot: snapshot, receipt: receipt, now: now, calendar: calendar) }
        return .result(value: RenewalIntentSupport.json(result))
    }
}

@available(iOS 16.0, *)
struct CompleteiCTRLRenewalRecoveryIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete iCTRL Renewal Recovery"
    static var description = IntentDescription("After the Shortcut restores its VPN, clear the matching recovery reservation. Interrupted work is failed without fabricating renewal success; original attempt dates govern next-day retry. This action does not switch VPN or bring iCTRL forward.")
    static var openAppWhenRun = false
    @Parameter(title: "Preparation Token") var prepareToken: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let now = Date(), calendar = Calendar.current
        let result = RenewalGateStore.transact(now: now, calendar: calendar) { $0.completeRecovery(token: prepareToken, now: now, calendar: calendar) }
        return .result(value: RenewalIntentSupport.json(result))
    }
}
