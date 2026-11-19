import SwiftUI

@main
struct CaptUpApp: App {
    var body: some Scene {
        WindowGroup {
            PortalView()
                .ignoresSafeArea()
        }
    }
}

struct PortalView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebController {
        WebController(configuration: WebController.mainConfiguration(), popup: false)
    }

    func updateUIViewController(_ uiViewController: WebController, context: Context) {}
}
