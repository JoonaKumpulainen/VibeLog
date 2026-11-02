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

    @UIApplicationDelegateAdaptor(AppOrientation.self) private var orientation

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
            if phase == .active { model.enteredForeground() }
        }
    }
}

/// The camera screen stays portrait and turns its own controls. Only the takes turn with the phone.
final class AppOrientation: NSObject, UIApplicationDelegate {
    private static var allowsTurning = false

    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.allowsTurning ? .allButUpsideDown : .portrait
    }

    static func allowTurning(_ allowed: Bool) {
        allowsTurning = allowed
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            var controller = scene.windows.first?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            if !allowed { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
        }
    }
}
