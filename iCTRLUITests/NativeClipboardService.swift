import Foundation
import UIKit

/// Authenticated native clipboard RPC. UIKit is touched only on main; each
/// operation owns the foreground transition until it finishes. Clipboard bodies
/// are never logged, placed in URLs, persisted, or sent through another app.
final class NativeClipboardService {
    typealias Reply = ([String: JSONValue]?, JSONRPCError?) -> Void
    private let stateLock = NSLock()
    private var busy = false
    private let navigation = DispatchQueue(label: "com.openminis.ictrl.native-clipboard.navigation")

    private final class Pending {
        let request: NativeClipboardRequest
        let reply: Reply
        let authorize: () -> JSONRPCError?
        let lock = NSLock()
        private var replied = false
        private(set) var mutationStarted = false
        var originalApp: String?
        var switched = false

        init(_ request: NativeClipboardRequest, authorize: @escaping () -> JSONRPCError?, reply: @escaping Reply) {
            self.request = request; self.authorize = authorize; self.reply = reply
        }
        var pending: Bool { lock.lock(); defer { lock.unlock() }; return !replied }
        func beginMutation() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !replied else { return false }
            mutationStarted = true
            return true
        }
        func send(_ value: [String: JSONValue]?, _ error: JSONRPCError?) {
            lock.lock(); let first = !replied; replied = true; lock.unlock()
            if first { reply(value, error) }
        }
        func timedOut() {
            lock.lock(); let changed = mutationStarted; lock.unlock()
            send(nil, NativeClipboardService.failure("clipboard_pending",
                "Native clipboard access has not finished. Check the iPhone for an Allow Paste prompt. Do not repeat the operation; it may still complete.",
                mutationStarted: changed, mayHaveCompleted: true, requiresUserAction: true))
        }
    }

    static func failure(_ reason: String, _ message: String, mutationStarted: Bool = false,
                        mayHaveCompleted: Bool = false, requiresUserAction: Bool = false) -> JSONRPCError {
        JSONRPCError(code: -32040, message: message, data: [
            "reason": .string(reason), "mutation_started": .bool(mutationStarted),
            "may_have_completed": .bool(mayHaveCompleted), "requires_user_action": .bool(requiresUserAction),
        ])
    }

    func handle(method: String, params: [String: JSONValue]?,
                authorize: @escaping () -> JSONRPCError?, completion: @escaping Reply) {
        let request: NativeClipboardRequest
        do { request = try NativeClipboardRequest(method: method, params: params) }
        catch let validation as NativeClipboardValidationError {
            completion(nil, Self.failure(validation.reason, "Clipboard parameters must be valid plain text, at most 65536 UTF-8 bytes, without NUL."))
            return
        } catch { completion(nil, Self.failure("invalid_params", "Invalid clipboard parameters.")); return }
        stateLock.lock()
        guard !busy else { stateLock.unlock(); completion(nil, Self.failure("busy", "Another native clipboard operation is still active. Do not repeat a pending operation.")); return }
        busy = true
        stateLock.unlock()
        let operation = Pending(request, authorize: authorize, reply: completion)
        // This timeout does NOT cancel an in-progress UIKit call or release the
        // busy guard. A permission prompt must not cause duplicate writes.
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { operation.timedOut() }
        DispatchQueue.main.async { self.prepare(operation) }
    }

    private func prepare(_ operation: Pending) {
        guard operation.pending else { release(); return }
        if let denied = operation.authorize() { operation.send(nil, denied); release(); return }
        guard !LockStateMonitor.shared().isLocked else {
            operation.send(nil, Self.failure("locked", "Unlock the iPhone manually before accessing its clipboard.", requiresUserAction: true)); release(); return
        }
        guard let ownID = Bundle.main.bundleIdentifier else {
            operation.send(nil, Self.failure("foreground_required", "Runner identity is unavailable.")); release(); return
        }
        if UIApplication.shared.applicationState == .active {
            operation.originalApp = ownID
            access(operation)
            return
        }
        guard operation.request.foreground else {
            operation.send(nil, Self.failure("foreground_required", "Native clipboard access needs the runner in the foreground.", requiresUserAction: true)); release(); return
        }
        // Metadata lookup is isolated from both main and the serial UI queue.
        // A wedged accessibility connection therefore cannot block HTTP replies.
        navigation.async {
            let original = ForegroundApp.currentBundleID()
            DispatchQueue.main.async {
                guard operation.pending else { self.release(); return }
                if operation.request.restoreApp && (original == nil || original == ownID) {
                    operation.send(nil, Self.failure("foreground_required", "Could not confirm the original foreground app. Open the runner first, or explicitly choose not to restore the app.", requiresUserAction: true))
                    self.release(); return
                }
                operation.originalApp = original
                guard ForegroundApp.openBundleID(ownID) else {
                    operation.send(nil, Self.failure("foreground_required", "Could not bring the runner to the foreground.", requiresUserAction: true)); self.release(); return
                }
                operation.switched = true
                self.waitForForeground(operation, until: Date().addingTimeInterval(2))
            }
        }
    }

    private func waitForForeground(_ operation: Pending, until deadline: Date) {
        if !operation.pending {
            finish(operation, value: nil, error: nil)
        } else if LockStateMonitor.shared().isLocked {
            finish(operation, value: nil, error: Self.failure("locked", "The iPhone locked before clipboard access. Unlock it manually.", requiresUserAction: true))
        } else if UIApplication.shared.applicationState == .active {
            access(operation)
        } else if Date() >= deadline {
            finish(operation, value: nil, error: Self.failure("foreground_required", "The runner did not become active; no clipboard access was attempted.", requiresUserAction: true))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForForeground(operation, until: deadline) }
        }
    }

    private func access(_ operation: Pending) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard operation.pending else { finish(operation, value: nil, error: nil); return }
        if let denied = operation.authorize() { finish(operation, value: nil, error: denied); return }
        guard UIApplication.shared.applicationState == .active, !LockStateMonitor.shared().isLocked else {
            finish(operation, value: nil, error: Self.failure("foreground_required", "Runner foreground access was lost; no new clipboard action was started.", requiresUserAction: true)); return
        }
        let board = UIPasteboard.general
        var result: [String: JSONValue] = ["native": .bool(true)]
        switch operation.request.method {
        case "clipboard_get":
            // A nonempty but unreadable board is NOT silently reported as empty.
            // UIPasteboard may wait here for the system paste-permission dialog.
            if board.numberOfItems == 0 {
                result["text"] = .string(""); result["has_text"] = .bool(false)
            } else if board.hasStrings, let text = board.string {
                do { try ClipboardTextPolicy.validate(text) }
                catch {
                    finish(operation, value: nil, error: Self.failure("text_too_large", "Clipboard text exceeds the supported 65536 UTF-8 byte limit or contains NUL.")); return
                }
                result["text"] = .string(text); result["has_text"] = .bool(true)
            } else {
                let reason = board.hasStrings ? "clipboard_unreadable" : "unsupported_clipboard"
                finish(operation, value: nil, error: Self.failure(reason, "The clipboard cannot be read as plain text. Check paste permission on the iPhone; images and rich-only data are unsupported.", requiresUserAction: true)); return
            }
            result["change_count"] = .int(board.changeCount)
        case "clipboard_set":
            guard operation.beginMutation(), let text = operation.request.text else { finish(operation, value: nil, error: nil); return }
            board.string = text
            result["written"] = .bool(true); result["utf8_bytes"] = .int(text.utf8.count)
        case "clipboard_clear":
            guard operation.beginMutation() else { finish(operation, value: nil, error: nil); return }
            board.items = []
            result["cleared"] = .bool(true)
        default:
            finish(operation, value: nil, error: Self.failure("invalid_params", "Unsupported clipboard method.")); return
        }
        finish(operation, value: result, error: nil)
    }

    private func finish(_ operation: Pending, value: [String: JSONValue]?, error: JSONRPCError?) {
        // Never override a user who already switched away while answering a
        // permission dialog. Only restore if this operation still owns front.
        guard operation.switched, operation.request.restoreApp,
              UIApplication.shared.applicationState == .active,
              let original = operation.originalApp else {
            var result = value
            if result != nil { result?["restored_app"] = .bool(!operation.switched) }
            operation.send(result, error); release(); return
        }
        navigation.async {
            var restored = false
            if ForegroundApp.openBundleID(original) {
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    if ForegroundApp.currentBundleID() == original { restored = true; break }
                    Thread.sleep(forTimeInterval: 0.1)
                } while Date() < deadline
            }
            var result = value
            if result != nil { result?["restored_app"] = .bool(restored) }
            operation.send(result, error)
            self.release()
        }
    }

    private func release() {
        stateLock.lock(); busy = false; stateLock.unlock()
    }
}
