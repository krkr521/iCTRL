import SwiftUI

@MainActor
struct FileTransferStatusView: View {
    @ObservedObject var receiver: CompanionFileReceiver
    private var hasFiles: Bool { !receiver.transfers.isEmpty || !receiver.localSavedFiles.isEmpty }
    private var current: FileTransferProgress? {
        receiver.transfers.last(where: { $0.isActive }) ?? receiver.transfers.last(where: { $0.stage == .failed }) ?? receiver.transfers.last
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(receiver.status, systemImage: "arrow.down.doc").font(.caption)
                Spacer(minLength: 4)
                if !receiver.failedIDs.isEmpty { Button("重试") { receiver.retryFailed() }.font(.caption) }
                if hasFiles {
                    Button("查看文件") { receiver.showTransfers = true }.font(.caption)
                }
            }
            if let row = current { transferRow(row) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $receiver.showTransfers, onDismiss: { receiver.closeDocument() }) {
            NavigationStack {
                Group {
                    if let document = receiver.openedDocument {
                        TransferDocumentView(url: document)
                    } else {
                        List {
                            if let message = receiver.openMessage {
                                Section { Text(message).font(.callout) }
                            }
                            ForEach(receiver.transfers) { row in
                                VStack(alignment: .leading) {
                                    transferRow(row).padding(.vertical, 4)
                                    if row.stage == .saved {
                                        Button("查看或分享") { receiver.requestOpen(id: row.id) }
                                    }
                                }
                            }
                            let visible = Set(receiver.transfers.map(\.id))
                            ForEach(receiver.localSavedFiles.filter { !visible.contains($0.id) }, id: \.id) { record in
                                Button { receiver.requestOpen(id: record.id) } label: {
                                    Label(record.name, systemImage: "doc")
                                }
                            }
                            Section {
                                Text("点按已保存的文件可查看或分享。IPA 等文件可能无法预览，请使用分享菜单选择支持的 App；是否显示 SideStore 由其文件类型支持决定。原文件仍位于「文件 → 我的 iPhone → iCTRL」。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle(receiver.openedDocument == nil ? "文件传输" : "所选文件")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if receiver.openedDocument != nil || receiver.openMessage != nil {
                            Button("返回列表") { receiver.closeDocument() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { receiver.showTransfers = false } }
                }
            }
        }
    }
    @ViewBuilder private func transferRow(_ row: FileTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name).font(.caption).lineLimit(1).truncationMode(.middle)
            HStack {
                Text(row.stage.label)
                Spacer(minLength: 4)
                if row.total > 0 {
                    Text("\(Int(row.fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(row.completed), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(row.total), countStyle: .file))")
                        .monospacedDigit()
                }
            }.font(.caption2).foregroundStyle(.secondary)
            if row.isActive {
                if row.total > 0 { ProgressView(value: row.fraction) }
                else { ProgressView().controlSize(.small) }
            }
        }
    }
}
