import SwiftUI
import UIKit

/// What the app knows about an attached projector or TV.
struct ExternalDisplayInfo: Equatable {
    var pointSize: CGSize
}

/// Drives the window shown on a projector.
///
/// iOS hands an app a separate scene for an external screen — over HDMI through a
/// USB-C or Lightning AV adapter, and equally over AirPlay. Declaring this scene is
/// what stops iOS from simply mirroring the phone: instead the projector gets a
/// clean output window while the phone keeps the editing interface.
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: OutputView(controller: .shared))
        // The projector shows the mapped output only: no letterbox chrome, no
        // safe-area insets, nothing but the canvas on black.
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window

        ShowController.shared.externalDisplay = ExternalDisplayInfo(pointSize: window.bounds.size)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ShowController.shared.externalDisplay = nil
        window = nil
    }
}
