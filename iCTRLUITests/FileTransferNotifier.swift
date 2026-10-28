import Foundation
import UserNotifications

/// Main-queue state notices only. Byte-level progress stays in the app UI.
final class FileTransferNotifier {
    static let category = TransferFileRoute.category
    static let openAction = TransferFileRoute.openAction
    private static let identifier = "ictrl.files.incoming"
    private var latest: [String: FileTransferNotice.Stage] = [:]
    private var order: [String] = []
    private var generation = 0

    func post(_ notice: FileTransferNotice, automationActive: @escaping () -> Bool) {
        // The companion posts saved notices itself, so cold-start taps are
        // delivered to its launch-time notification delegate, not an XCTest runner.
        if notice.stage == .saved {
            generation += 1
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            return
        }
        guard latest[notice.id] != notice.stage else { return }
        if latest[notice.id] == nil { order.append(notice.id) }
        latest[notice.id] = notice.stage
        while order.count > FileTransferStore.maxMetadata { latest.removeValue(forKey: order.removeFirst()) }
        generation += 1
        let current = generation
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self, self.generation == current,
                      [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
                let content = UNMutableNotificationContent()
                content.title = notice.title
                content.body = notice.body
                content.categoryIdentifier = Self.category
                content.userInfo = ["file_transfer_stage": notice.stage.rawValue, TransferFileRoute.idKey: notice.id]
                content.interruptionLevel = FileTransferNotice.permitsBanner(stage: notice.stage, automationActive: automationActive()) ? .active : .passive
                // Fixed identifier updates a single generic card; no filenames,
                // paths, payloads or secrets are exposed on the lock screen.
                center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
                center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            }
        }
    }
}
