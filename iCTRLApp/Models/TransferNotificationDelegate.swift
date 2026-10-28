import UIKit
import UserNotifications
import Combine

/// Installed before didFinishLaunching returns, including notification cold starts.
final class TransferNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published private(set) var selectedID: String?
    private static let savedLock = NSLock()
    private static var savedGeneration: UInt64 = 0
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: TransferFileRoute.openAction, title: "查看文件",
                                          options: [.foreground, .authenticationRequired])
        center.setNotificationCategories([UNNotificationCategory(identifier: TransferFileRoute.category,
            actions: [action], intentIdentifiers: [], options: [])])
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let id = TransferFileRoute.selectedID(category: content.categoryIdentifier,
            action: response.actionIdentifier, defaultAction: UNNotificationDefaultActionIdentifier,
            payloadID: content.userInfo[TransferFileRoute.idKey] as? String)
        DispatchQueue.main.async {
            if let id { self.selectedID = id }
            completionHandler()
        }
    }
    func consume() { selectedID = nil }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Receiving a notice alone never navigates, opens a file, or steals focus.
        completionHandler([.list])
    }
    static func postSaved(id: String) {
        guard TransferFileRoute.validID(id) else { return }
        savedLock.lock(); savedGeneration &+= 1; let generation = savedGeneration; savedLock.unlock()
        let content = UNMutableNotificationContent()
        content.title = "iCTRL 文件已保存"
        content.body = "点按可直接查看或分享文件。"
        content.categoryIdentifier = TransferFileRoute.category
        content.userInfo = [TransferFileRoute.idKey: id]
        content.interruptionLevel = .passive
        // One generic card; no filename, path, hash, content, or pairing data.
        let center = UNUserNotificationCenter.current()
        let post = {
            savedLock.lock(); defer { savedLock.unlock() }
            guard savedGeneration == generation else { return }
            center.add(UNNotificationRequest(identifier: "ictrl.files.saved", content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                // Provisional permission delivers quietly; no new blocking prompt.
                center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
                    if granted { post() }
                }
            } else if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) { post() }
        }
    }
}
