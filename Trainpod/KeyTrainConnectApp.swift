import SwiftUI

@main
struct KeyTrainConnectApp: App {
    @StateObject private var manifestManager = TransitManifestManager.shared
    @AppStorage(TransitAgency.preferenceKey) private var selectedAgency = TransitAgency.cta.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(BLEAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manifestManager)
                .task(id: selectedAgency) {
                    let systemID = (TransitAgency(rawValue: selectedAgency) ?? .cta).systemID
                    manifestManager.activate(systemId: systemID)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { FileLogger.shared.log("[APP] App became active"); PhoneDiagnosticLog.shared.record("APP_FOREGROUND") }
            if phase == .background { FileLogger.shared.log("[APP] App entered background"); PhoneDiagnosticLog.shared.record("APP_BACKGROUND") }
        }
    }
}
