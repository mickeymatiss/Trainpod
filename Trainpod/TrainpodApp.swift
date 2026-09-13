import SwiftUI

@main
struct TrainpodApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(BLEAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { FileLogger.shared.log("[APP] App became active"); PhoneDiagnosticLog.shared.record("APP_FOREGROUND") }
            if phase == .background { FileLogger.shared.log("[APP] App entered background"); PhoneDiagnosticLog.shared.record("APP_BACKGROUND") }
        }
    }
}
