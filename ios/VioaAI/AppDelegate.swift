import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    /// Fallback when iOS launches the app through the `vioaai://` deep link
    /// instead of returning into the authentication session.
    static var pendingAuthCode: String?
    static let authCodeNotification = Notification.Name("vioa.nativeAuthCode")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.configureAudioSession()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = UIColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = WebViewController()
        window.makeKeyAndVisible()
        self.window = window

        if let url = launchOptions?[.url] as? URL {
            _ = handleAuthURL(url)
        }

        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        return handleAuthURL(url)
    }

    @discardableResult
    private func handleAuthURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "vioaai" else { return false }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return false }

        AppDelegate.pendingAuthCode = code
        NotificationCenter.default.post(name: AppDelegate.authCodeNotification, object: code)
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Phone calls and Siri deactivate the session; wake it again so voice
        // chat keeps working when the user comes back to the app.
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Voice chat inside the web view needs a `.playAndRecord` session with the
    /// speaker as the default output, otherwise the microphone is muted by
    /// iOS as soon as the recorder starts.
    private static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
        } catch {
            // Keep the system default; only voice input is affected.
        }
    }
}
