import SwiftUI

@main
struct iCTRLApp: App {
    @UIApplicationDelegateAdaptor(TransferNotificationDelegate.self) private var transferNotifications
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var fileReceiver = CompanionFileReceiver()
    @StateObject private var appState = AppState()
    @StateObject private var permission = NetworkPermission()
    /// Clients and log of the runner on this device; shared by Settings and Logs.
    @StateObject private var runnerAdmin = RunnerAdmin(port: 8200)
    @State private var showPermissionAlert = false
    /// Outcome of a pairing file shared to the app, shown as an alert.
    @State private var sharedPairing: SharedPairingResult?

    struct SharedPairingResult: Identifiable {
        let id = UUID()
        let fileName: String
        let error: String?
    }

    init() {
        // Touch the logger during init so every run produces a file, even one
        // that crashes before the user does anything.
        ictrlLog("App launched")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
            }
            .environmentObject(appState)
            .environmentObject(runnerAdmin)
            .safeAreaInset(edge: .bottom) { FileTransferStatusView(receiver: fileReceiver) }
            .task(id: scenePhase) {
                if scenePhase == .active { await fileReceiver.run() }
            }
            .sheet(item: $appState.pendingAuthRequest) { request in
                AuthRequestView(request: request)
                    .environmentObject(appState)
            }
            // A pairing file shared to iCTRL from another app (Files, Mail,
            // AirDrop, a chat): validate, store, and say so either way.
            .onReceive(transferNotifications.$selectedID) { id in
                guard let id else { return }
                transferNotifications.consume()
                fileReceiver.requestOpen(id: id)
            }
            .onOpenURL { url in
                if let id = TransferFileRoute.parse(url) { fileReceiver.requestOpen(id: id); return }
                guard url.isFileURL else { StartupCoordinator.shared.receive(url); return }
                let name = url.lastPathComponent
                do {
                    try PairingFileStore.importShared(from: url)
                    ictrlLog("Pairing file received via share: \(name)")
                    sharedPairing = SharedPairingResult(fileName: name, error: nil)
                } catch {
                    ictrlLog("Shared file \(name) rejected: \(error.localizedDescription)")
                    sharedPairing = SharedPairingResult(fileName: name, error: error.localizedDescription)
                }
            }
            .alert(item: $sharedPairing) { result in
                if let error = result.error {
                    return Alert(title: Text(L10n.t(.pairingRejectedTitle)),
                                 message: Text("\(result.fileName)\n\n\(error)"),
                                 dismissButton: .default(Text(L10n.t(.doneButton))))
                }
                return Alert(title: Text(L10n.t(.pairingReceivedTitle)),
                             message: Text(String(format: L10n.t(.pairingReceivedBody), result.fileName)),
                             dismissButton: .default(Text(L10n.t(.doneButton))))
            }
            // On a fresh install this raises the system prompts; afterwards it
            // only reads them back, and a denial is said once per launch.
            .task { permission.probe() }
            .onReceive(permission.$networkData.combineLatest(permission.$localNetwork)) { _ in
                if !permission.denied.isEmpty { showPermissionAlert = true }
            }
            .alert(L10n.t(.networkPermissionTitle), isPresented: $showPermissionAlert) {
                Button(L10n.t(.openSettings)) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
                Button(L10n.t(.laterButton), role: .cancel) {}
            } message: {
                Text(String(format: L10n.t(.networkPermissionBody), permission.denied.joined(separator: ", ")))
            }
        }
    }
}
