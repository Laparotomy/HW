import SwiftUI

/// The projector's view of the show: the canvas, letterboxed on black, and nothing else.
///
/// Deliberately shares the renderer with the phone's stage rather than duplicating
/// it, so the two can never drift apart — the projector is showing the same frame,
/// not a second interpretation of the project.
struct OutputView: View {
    @ObservedObject var controller: ShowController

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.fitting(aspect: controller.project.canvasAspect)
            ZStack {
                Color.black
                if controller.renderer != nil {
                    MetalStageView(controller: controller)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}
