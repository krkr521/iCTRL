import SwiftUI
import QuickLook

/// Only receives a private, content-verified snapshot from CompanionFileReceiver.
struct TransferDocumentView: View {
    let url: URL
    var body: some View {
        VStack(spacing: 16) {
            Text(url.lastPathComponent).font(.headline).lineLimit(3).padding(.horizontal)
            if QLPreviewController.canPreview(url as NSURL) {
                TransferQuickLook(url: url)
            } else {
                Spacer()
                Image(systemName: "doc").font(.system(size: 52)).foregroundStyle(.secondary)
                Text("此类型不支持预览，文件已准备好分享。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
            }
            ShareLink(item: url) { Label("分享或在其他 App 打开", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).padding(.bottom)
        }
    }
}

private struct TransferQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
