import SwiftUI

@MainActor
struct FileTransferStatusView: View {
    @ObservedObject var receiver: CompanionFileReceiver
    @State private var showTransfers = false
    private var current: FileTransferProgress? {
        receiver.transfers.last(where: { $0.isActive }) ?? receiver.transfers.last(where: { $0.stage == .failed }) ?? receiver.transfers.last
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(receiver.status, systemImage: "arrow.down.doc").font(.caption)
                Spacer(minLength: 4)
                if !receiver.failedIDs.isEmpty { Button("重试") { receiver.retryFailed() }.font(.caption) }
                if !receiver.transfers.isEmpty {
                    Button("查看文件") { showTransfers = true }.font(.caption)
                }
            }
            if let row = current { transferRow(row) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showTransfers) {
            NavigationStack {
                List {
                    ForEach(receiver.transfers) { row in transferRow(row).padding(.vertical, 4) }
                    Section {
                        Text("保存后的文件位于「文件 → 我的 iPhone → iCTRL」。接收和保存期间请保持 iCTRL 在前台。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("文件传输")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showTransfers = false } } }
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
