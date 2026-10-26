import Foundation
import UIKit

/// Local startup orchestration, shared by AppIntents and local URL callbacks.
/// A successful URL open is not proof that Runner is listening.
@MainActor
final class StartupCoordinator: ObservableObject {
    static let shared = StartupCoordinator()
    @Published private(set) var lastResult: String = ""
    private var preparing = false
    private var handlingURL = false
    private let mounter = DDIMounter()
    private var pendingRequestID: String?
    private var runnerMetadata: [String: JSONValue]?

    private func base() -> [String: JSONValue] {
        let expiry = ProvisioningExpiry.currentISO8601()
        return [
            "ok": .bool(false), "status": .string("checking"), "reason": .null,
            "renewal_receipt": RenewalReceiptStore.currentJSON(),
            "renewal_gate": .object(RenewalGateStore.plan()),
            "ddi_mounted": .bool(DeveloperDiskImage.status().isMounted),
            "pairing_present": .bool(PairingFileStore.exists),
            "image_files_present": .bool(DeveloperDiskImageStore.isComplete),
            "server_running": .bool(false), "server_version": .null,
            "companion_bundle_id": Bundle.main.bundleIdentifier.map(JSONValue.string) ?? .null,
            "companion_team_identifier": ProvisioningExpiry.currentTeamIdentifier().map(JSONValue.string) ?? .null,
            "companion_profile_expires_at": expiry.map(JSONValue.string) ?? .null,
            "companion_profile_expiry_available": .bool(expiry != nil),
            "runner_bundle_id": .null, "runner_team_identifier": .null,
            "runner_profile_expires_at": .null, "runner_profile_expiry_verified": .bool(false),
            "sidestore_profile_expiry_available": .bool(false),
            "cross_app_auto_lock_prevention": .bool(false),
        ]
    }

    private func schema() async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8200/schema")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["server_version"] is String, object["methods"] is [Any] else { return nil }
        return object
    }

    private func finish(_ report: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder().encode(report)) ?? Data("{}".utf8)
        let result = String(decoding: data, as: UTF8.self)
        lastResult = result
        return result
    }

    private func failed(_ reason: String, message: String? = nil) -> String {
        var report = base()
        report["status"] = .string("needs_attention")
        report["reason"] = .string(reason)
        if let message { report["message"] = .string(message) }
        return finish(report)
    }

    func status() async -> String {
        var report = base()
        if let schema = await schema() {
            report["server_running"] = .bool(true)
            report["server_version"] = (schema["server_version"] as? String).map(JSONValue.string) ?? .null
            report["ok"] = .bool(DeveloperDiskImage.status().isMounted)
            report["status"] = .string("running")
        } else {
            report["status"] = .string("stopped")
            report["reason"] = .string(DeveloperDiskImage.status().isMounted ? "runner_stopped" : "ddi_missing")
        }
        // Status does not bring Runner forward, so it does not claim a fresh
        // Runner profile date. Prepare provides fresh nonce-matched metadata.
        return finish(report)
    }

    func prepare(mountIfNeeded: Bool = true, keepAwake: Bool = true) async -> String {
        guard !preparing else { return failed("busy") }
        preparing = true
        defer { preparing = false; pendingRequestID = nil; runnerMetadata = nil }
        ForegroundKeepAwake.shared.install()
        ForegroundKeepAwake.shared.setEnabled(keepAwake)
        if !DeveloperDiskImage.status().isMounted {
            guard mountIfNeeded else { return failed("ddi_missing") }
            guard PairingFileStore.exists else { return failed("pairing_missing") }
            guard DeveloperDiskImageStore.isComplete else { return failed("image_files_missing") }
            // Uses the existing FFI mount worker with its dedicated 4 MB stack.
            // Does not silently switch, configure or disconnect any VPN.
            await mounter.mount()
            guard DeveloperDiskImage.status().isMounted else {
                if case .failed(let message) = mounter.phase { return failed("ddi_mount_failed", message: message) }
                return failed("ddi_mount_failed")
            }
        }
        let requestID = UUID().uuidString
        pendingRequestID = requestID
        runnerMetadata = nil
        var callback = URLComponents(string: "ictrl-app://started")!
        callback.queryItems = [URLQueryItem(name: "request_id", value: requestID)]
        let metadata: [String: JSONValue] = [
            "companion_profile_expires_at": ProvisioningExpiry.currentISO8601().map(JSONValue.string) ?? .null,
            "companion_bundle_id": Bundle.main.bundleIdentifier.map(JSONValue.string) ?? .null,
            "companion_team_identifier": ProvisioningExpiry.currentTeamIdentifier().map(JSONValue.string) ?? .null,
            "renewal_receipt": RenewalReceiptStore.currentJSON(),
            "renewal_gate": .object(RenewalGateStore.plan()),
        ]
        let metadataJSON = String(decoding: (try? JSONEncoder().encode(metadata)) ?? Data("{}".utf8), as: UTF8.self)
        var launch = URLComponents(string: "ictrl://start")!
        launch.queryItems = [URLQueryItem(name: "callback", value: callback.url!.absoluteString),
                             URLQueryItem(name: "request_id", value: requestID),
                             URLQueryItem(name: "companion_metadata", value: metadataJSON),
                             URLQueryItem(name: "include_profile_expiry", value: "1"),
                             URLQueryItem(name: "keep_awake", value: keepAwake ? "1" : "0")]
        // A short, finite background task only covers the Runner handoff. This
        // is not a permanent background keepalive or an Auto-Lock override.
        let lease = UIApplication.shared.beginBackgroundTask(withName: "iCTRL startup handoff", expirationHandler: nil)
        defer { if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) } }
        let opened: Bool = await withCheckedContinuation { continuation in
            UIApplication.shared.open(launch.url!, options: [:]) { continuation.resume(returning: $0) }
        }
        guard opened else { return failed("runner_unavailable") }
        let deadline = Date().addingTimeInterval(12)
        var liveSchema: [String: Any]?
        while Date() < deadline {
            liveSchema = await schema()
            if liveSchema != nil && runnerMetadata != nil { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let liveSchema else { return failed("runner_not_responding") }
        var report = base()
        report["ok"] = .bool(true)
        report["status"] = .string("running")
        report["server_running"] = .bool(true)
        report["server_version"] = (liveSchema["server_version"] as? String).map(JSONValue.string) ?? .null
        if let metadata = runnerMetadata { report.merge(metadata) { _, fresh in fresh } }
        ForegroundKeepAwake.shared.setServiceRunning(true)
        return finish(report)
    }

    func receive(_ url: URL) {
        guard url.scheme == "ictrl-app" else { return }
        if url.host == "started" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ key: String) -> String? { query.first(where: { $0.name == key })?.value }
            guard let expected = pendingRequestID, value("request_id") == expected,
                  value("status") == "ready" else { return }
            let expiry = value("runner_profile_expires_at").flatMap { ISO8601DateFormatter().date(from: $0) }
            var metadata: [String: JSONValue] = [
                "runner_profile_expires_at": expiry.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "runner_profile_expiry_verified": .bool(expiry != nil && value("runner_profile_expiry_available") == "1"),
            ]
            for key in ["runner_bundle_id", "runner_team_identifier"] {
                if let text = value(key), text.count <= 255 { metadata[key] = .string(text) }
            }
            runnerMetadata = metadata
            return
        }
        guard let request = try? StartupURLRequest(url: url), !handlingURL else { return }
        handlingURL = true
        Task {
            defer { handlingURL = false }
            let json: String
            switch request.operation {
            case .status: json = await status()
            case .prepare: json = await prepare(mountIfNeeded: request.mountIfNeeded, keepAwake: request.keepAwake)
            }
            guard let callback = request.callback,
                  var components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { return }
            var query = components.queryItems ?? []
            query.append(URLQueryItem(name: "ictrl_result", value: json))
            components.queryItems = query
            if let resultURL = components.url { _ = await UIApplication.shared.open(resultURL) }
        }
    }
}
