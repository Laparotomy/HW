import SwiftUI

@main
struct VideoMapperApp: App {
    @StateObject private var controller = ShowController(
        project: ProjectStore.shared.loadAll().first ?? .demo)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .preferredColorScheme(.dark)
                .onAppear {
                    // A projection show is watched, not touched; letting the screen
                    // lock mid-set would kill the output.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                controller.saveNow()
                UIApplication.shared.isIdleTimerDisabled = false
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
            @unknown default:
                break
            }
        }
    }
}
