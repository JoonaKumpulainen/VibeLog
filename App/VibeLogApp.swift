import SwiftUI
import UIKit
import VLCore

@main
struct VibeLogApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Log.shared.installCrashHandlers()
        Log.shared.info("VibeLog started on \(SystemStatus.deviceModel), "
            + "\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    model.onAppear()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Permission prompts make the app inactive for a moment, so only background counts.
            if phase == .background { model.enteredBackground() }
        }
    }
}
