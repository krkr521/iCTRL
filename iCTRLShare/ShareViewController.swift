import UIKit
import UniformTypeIdentifiers
import CryptoKit

/// Standalone authenticated local client. No shared container/keychain needed.
final class ShareViewController: UIViewController {
    private let client = RunnerClient(port: 8200, clientName: "iCTRL Share", account: "runner-file-share")
    private let label = UILabel()
    private var task: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0; label.textAlignment = .center
        label.text = "Send to computer through iCTRL\nRunner must already be running."
        let send = UIButton(type: .system); send.setTitle("Send files", for: .normal); send.addTarget(self, action: #selector(begin), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel", for: .normal); cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, send, cancel]); stack.axis = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: view.centerYAnchor), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)])
    }
    @objc private func begin() {
        guard task == nil else { return }
        task = Task { @MainActor in
            do {
                if !client.isPaired {
                    label.text = "Approve iCTRL Share in the Runner notification, then return here."
                    try await client.pair()
                }
                let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                guard !providers.isEmpty, providers.count <= 4 else { throw CocoaError(.fileReadUnsupportedScheme) }
                for provider in providers {
                    try Task.checkCancellation()
                    let url = try await stage(provider)
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    try await upload(url)
                }
                label.text = "Sent. Download the files from iCTRL on your computer."
                extensionContext?.completeRequest(returningItems: nil)
            } catch is CancellationError { extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
            catch { label.text = "Not sent. Ensure Runner is running and approve iCTRL Share when asked. Keep this sheet open until completion."; task = nil }
        }
    }
    @objc private func cancelShare() {
        task?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
    private func stage(_ provider: NSItemProvider) async throws -> URL {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                do {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize, size <= FileTransferStore.maxFile else { throw CocoaError(.fileReadUnknown) }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let staged = directory.appendingPathComponent(FileTransferStore.safeName(provider.suggestedName ?? url.lastPathComponent))
                    // Provider URLs expire when this callback returns.
                    do {
                        guard FileManager.default.createFile(atPath: staged.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
                        let output = try FileHandle(forWritingTo: staged); defer { try? output.close() }
                        var bytes = 0
                        while let data = try input.read(upToCount: FileTransferStore.chunkSize), !data.isEmpty {
                            bytes += data.count
                            guard bytes <= FileTransferStore.maxFile else { throw CocoaError(.fileReadUnknown) }
                            try output.write(contentsOf: data)
                        }
                        guard bytes == size else { throw CocoaError(.fileReadCorruptFile) }
                        continuation.resume(returning: staged)
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        throw error
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    @MainActor private func upload(_ url: URL) async throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let reply = try await client.call("file_begin", ["direction": "phone_to_pc", "name": url.lastPathComponent, "size": size])
        guard let id = reply["id"] as? String else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var digest = SHA256(); var offset = 0
            while let chunk = try handle.read(upToCount: FileTransferStore.chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                _ = try await client.call("file_write", ["id": id, "offset": offset, "data": chunk.base64EncodedString()])
                digest.update(data: chunk); offset += chunk.count
                label.text = "Sending \(url.lastPathComponent): \(offset) / \(size) bytes"
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            _ = try await client.call("file_commit", ["id": id, "sha256": hash])
        } catch {
            _ = try? await client.call("file_delete", ["id": id]); throw error
        }
    }
}
