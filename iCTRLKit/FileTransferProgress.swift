import Foundation

/// Display facts only; a full upload is never treated as a saved document.
struct FileTransferProgress: Identifiable, Equatable {
    enum Stage: String {
        case receiving, verifying, waiting, saving, saved, savedElsewhere, awaitingReceipt, failed
        var label: String {
            switch self {
            case .receiving: return "正在接收"
            case .verifying: return "接收完毕，等待校验"
            case .waiting: return "已接收，等待保存"
            case .saving: return "正在保存到文件"
            case .saved: return "已保存到文件"
            case .savedElsewhere: return "已在其他接收端保存"
            case .awaitingReceipt: return "文件已写入，等待确认"
            case .failed: return "接收或保存失败"
            }
        }
    }
    let id: String
    var name: String
    let total: Int
    var completed: Int
    var stage: Stage
    var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : (stage == .saved ? 1 : 0) }
    var isActive: Bool { ![.saved, .savedElsewhere, .failed].contains(stage) }

    init?(metadata: [String: JSONValue]) {
        guard let id = metadata["id"]?.stringValue, UUID(uuidString: id) != nil,
              let name = metadata["name"]?.stringValue,
              case let .int(total)? = metadata["size"], total >= 0, total <= FileTransferStore.maxFile,
              case let .int(completed)? = metadata["received"], completed >= 0, completed <= total,
              let state = metadata["state"]?.stringValue else { return nil }
        self.id = id; self.name = FileTransferStore.safeName(name); self.total = total; self.completed = completed
        switch state {
        case "uploading": self.stage = total > 0 && completed == total ? .verifying : .receiving
        case "ready":
            guard completed == total else { return nil }
            self.stage = .waiting
        case "saved":
            guard completed == total, metadata["saved"]?.boolValue == true else { return nil }
            self.stage = metadata["receipt_source"]?.stringValue == "companion_client_report" ? .saved : .savedElsewhere
            self.name = FileTransferStore.safeName(metadata["saved_name"]?.stringValue ?? self.name)
        case "failed": self.stage = .failed
        default: return nil
        }
    }
}

enum TransferDestinationName {
    static func make(_ raw: String, collision: Int) -> String {
        let safe = FileTransferStore.safeName(raw)
        var stem = Array((safe as NSString).deletingPathExtension.unicodeScalars)
        var ext = Array((safe as NSString).pathExtension.unicodeScalars)
        let counter = collision == 0 ? "" : " (\(collision))"
        func value() -> String {
            String(String.UnicodeScalarView(stem)) + counter
                + (ext.isEmpty ? "" : "." + String(String.UnicodeScalarView(ext)))
        }
        while value().unicodeScalars.count > 120 || value().utf8.count > 240 {
            if stem.count > 1 { stem.removeLast() }
            else if !ext.isEmpty { ext.removeLast() }
            else { break }
        }
        return FileTransferStore.safeName(value())
    }
    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255
            && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

/// Notification input omits filenames, paths, hashes, owners and lease secrets.
struct FileTransferNotice: Equatable {
    enum Stage: String { case receiving, ready, saved }
    let id: String
    let stage: Stage
    static func permitsBanner(stage: Stage, automationActive: Bool) -> Bool {
        !automationActive && stage != .receiving
    }
    static func event(method: String, params: [String: JSONValue], result: [String: JSONValue]) -> FileTransferNotice? {
        guard let id = result["id"]?.stringValue, UUID(uuidString: id) != nil else { return nil }
        if method == "file_begin", params["direction"]?.stringValue == "pc_to_phone" { return .init(id: id, stage: .receiving) }
        guard result["direction"]?.stringValue == "pc_to_phone" else { return nil }
        if method == "file_commit", result["state"]?.stringValue == "ready" { return .init(id: id, stage: .ready) }
        if method == "file_saved", result["state"]?.stringValue == "saved", result["saved"]?.boolValue == true,
           result["receipt_source"]?.stringValue == "companion_client_report" { return .init(id: id, stage: .saved) }
        return nil
    }
    var title: String { stage == .saved ? "iCTRL 文件已保存" : "iCTRL 收到文件" }
    var body: String {
        switch stage {
        case .receiving: return "正在接收文件。打开 iCTRL 可查看进度。"
        case .ready: return "文件已接收，打开 iCTRL 完成保存。"
        case .saved: return "请在「文件 → 我的 iPhone → iCTRL」中查看。"
        }
    }
}
