import AVFoundation
import UIKit

/// Something that wants Siri Remote input before UIKit's focus system gets it.
@MainActor
protocol RemoteEventHandler: AnyObject {
    /// Returns true when the event was used up and must not continue to UIKit.
    func handleRemoteEvent(_ event: UIEvent) -> Bool
}

/// Hands every remote event to the browser first.
///
/// A web page has nothing the tvOS focus engine can focus, and once a page starts playing video
/// the normal responder chain stops being a dependable way to hear about button presses. Reading
/// events here works in both situations.
final class BrowserApplication: UIApplication {
    weak var remoteEventHandler: RemoteEventHandler?

    override func sendEvent(_ event: UIEvent) {
        if let handler = remoteEventHandler, handler.handleRemoteEvent(event) {
            return
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var browser: BrowserViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let browser = BrowserViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window
        self.browser = browser
        (UIApplication.shared as? BrowserApplication)?.remoteEventHandler = browser
    }

    func sceneWillResignActive(_ scene: UIScene) {
        browser?.saveSession()
    }
}
