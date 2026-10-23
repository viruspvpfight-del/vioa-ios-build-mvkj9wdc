import UIKit
import WebKit
import AuthenticationServices

/// The app's single screen: a full-screen WKWebView pointed at vioa.site.
///
/// Feature parity with the Android shell:
///  * stays inside vioa.site, external links open in Safari
///  * `window.open()` / Google Sign-In popups
///  * native JS alert / confirm / prompt dialogs
///  * file uploads through the document picker
///  * microphone access for voice chat
///  * downloads saved to Files app (`On My iPhone › Vioa AI › Downloads`)
///  * pull to refresh, back/forward gestures, native update notice
final class WebViewController: UIViewController {

    // MARK: - Configuration

    private static let homeURL = URL(string: "https://vioa.site/")!
    private static let downloadsPage = URL(string: "https://vioa.site/downloads/")!
    private static let versionURL = URL(string: "https://vioa.site/downloads/app-version.json")!
    private static let ownHost = "vioa.site"
    private static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.6"

    private let background = UIColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
    private var authSession: ASWebAuthenticationSession?
    private var webViewBottom: NSLayoutConstraint?

    /// A real Safari identity plus an app marker, so the site can render the
    /// native chrome while Google still recognises the browser.
    private static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/18.6 Mobile/15E148 Safari/604.1 VioaAI/\(appVersion)"
    }

    /// Runs before the first paint: marks the page as the native app, exposes the
    /// bridge object, and installs the iOS-style surface (the detailed look lives
    /// in the site's stylesheet under `html.vioa-app`).
    private static let appChromeScript: String = {
        let css = """
        html.vioa-app{background:#0b0b0f;-webkit-text-size-adjust:100%;text-size-adjust:100%}
        html.vioa-app ::-webkit-scrollbar{width:0;height:0;display:none}
        html.vioa-app body{-webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent;overscroll-behavior-y:none}
        html.vioa-app input,html.vioa-app textarea,html.vioa-app select{font-size:16px}
        html.vioa-app .ios-sheet{display:none!important}
        """
        return """
        (function(){
          var css = `\(css)`;
          window.vioaNative = { platform: 'ios', version: '\(appVersion)', googleAuth: true };
          window.__vioaKb = function (h) {
            document.documentElement.style.setProperty('--vioa-kb', (h > 0 ? h : 0) + 'px');
            return true;
          };
          function paint() {
            var root = document.documentElement;
            if (!root) { setTimeout(paint, 8); return; }
            root.classList.add('vioa-app');
            if (!document.getElementById('vioa-app-css')) {
              var s = document.createElement('style');
              s.id = 'vioa-app-css';
              s.appendChild(document.createTextNode(css));
              (document.head || root).appendChild(s);
            }
          }
          paint();
          document.addEventListener('DOMContentLoaded', paint);
        })();
        """
    }()

    // MARK: - Views

    private var webView: WKWebView!
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let refreshControl = UIRefreshControl()
    private var updatePill: UIButton?
    private var updatePillVersion: String?

    private let errorPanel = UIView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    // MARK: - State

    private var progressObservation: NSKeyValueObservation?
    private var popup: PopupWebViewController?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var didCheckForUpdates = false

    // MARK: - Lifecycle

    override func loadView() {
        let root = UIView()
        root.backgroundColor = background
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background
        configureWebView()
        configureChrome()
        configureErrorPanel()
        observeKeyboard()
        observeAuth()
        if let code = AppDelegate.pendingAuthCode {
            AppDelegate.pendingAuthCode = nil
            finishNativeSignIn(code: code)
        } else {
            loadHome()
        }
        checkForUpdates()
    }

    deinit {
        progressObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "vioaAuth")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - Setup

    private func configureWebView() {
        let configuration = WKWebViewConfiguration()
        // Same store as Safari-style persistence: cookies and localStorage survive relaunches.
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.suppressesIncrementalRendering = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        if #available(iOS 14.5, *) {
            configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        // Native auth bridge: the web app asks us to run Google sign-in in a real
        // browser session (Google blocks OAuth inside embedded web views).
        configuration.userContentController.add(self, name: "vioaAuth")

        // Paint the native look before the first frame so there is no flash.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.appChromeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webView)

        let bottom = webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        webViewBottom = bottom

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            bottom,
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        refreshControl.tintColor = .white
        refreshControl.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
        webView.scrollView.alwaysBounceVertical = true

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self else { return }
            let value = Float(webView.estimatedProgress)
            self.progressBar.progress = value
            self.progressBar.isHidden = value >= 1.0
        }
    }

    private func configureChrome() {
        progressBar.progressTintColor = .white
        progressBar.trackTintColor = .clear
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private func configureErrorPanel() {
        errorPanel.backgroundColor = background
        errorPanel.isHidden = true
        errorPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorPanel)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "لا يوجد اتصال · No connection"
        title.textColor = .white
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textAlignment = .center
        title.numberOfLines = 0

        errorLabel.text = "تعذّر تحميل vioa.site.\nCould not load vioa.site."
        errorLabel.textColor = UIColor(white: 0.65, alpha: 1)
        errorLabel.font = .systemFont(ofSize: 14)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0

        retryButton.setTitle("إعادة المحاولة · Retry", for: .normal)
        retryButton.setTitleColor(.black, for: .normal)
        retryButton.backgroundColor = .white
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 11, left: 22, bottom: 11, right: 22)
        retryButton.layer.cornerRadius = 12
        if #available(iOS 13.0, *) {
            retryButton.layer.cornerCurve = .continuous
        }
        retryButton.layer.masksToBounds = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(retryButton)
        errorPanel.addSubview(stack)

        NSLayoutConstraint.activate([
            errorPanel.topAnchor.constraint(equalTo: view.topAnchor),
            errorPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            stack.centerYAnchor.constraint(equalTo: errorPanel.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: errorPanel.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorPanel.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: errorPanel.trailingAnchor, constant: -28),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func loadHome() {
        var request = URLRequest(url: Self.homeURL)
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
    }

    @objc private func pullToRefresh() {
        webView.reload()
    }

    @objc private func retryTapped() {
        errorPanel.isHidden = true
        loadHome()
    }

    // MARK: - Update notice

    /// Reads `/downloads/app-version.json` (the same file the Android app uses)
    /// and shows a small "تحديث · Update" pill when a newer version exists.
    private func checkForUpdates() {
        guard !didCheckForUpdates else { return }
        didCheckForUpdates = true

        var request = URLRequest(url: Self.versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard
                let self = self,
                let data = data,
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any]
            else { return }

            let latest = (dictionary["iosVersion"] as? String) ?? (dictionary["version"] as? String)
            guard let latestVersion = latest, self.isNewer(latestVersion, than: Self.appVersion) else { return }

            if UserDefaults.standard.string(forKey: "vioa.dismissedUpdate") == latestVersion { return }
            DispatchQueue.main.async {
                self.showUpdatePill(version: latestVersion)
            }
        }.resume()
    }

    private func showUpdatePill(version: String) {
        updatePillVersion = version
        if updatePill == nil {
            let button = UIButton(type: .system)
            button.setTitle("🔄 تحديث · Update", for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.backgroundColor = UIColor(white: 0.11, alpha: 0.97)
            button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 13, bottom: 7, right: 13)
            button.layer.cornerRadius = 14
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
            button.translatesAutoresizingMaskIntoConstraints = false
            button.addTarget(self, action: #selector(updatePillTapped), for: .touchUpInside)
            view.addSubview(button)

            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 54),
                button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            ])
            updatePill = button
        }
        updatePill?.isHidden = false
    }

    @objc private func updatePillTapped() {
        updatePill?.isHidden = true
        if let version = updatePillVersion {
            UserDefaults.standard.set(version, forKey: "vioa.dismissedUpdate")
        }
        webView.load(URLRequest(url: Self.downloadsPage))
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let newParts = candidate.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let oldParts = current.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        for index in 0..<max(newParts.count, oldParts.count) {
            let newValue = index < newParts.count ? newParts[index] : 0
            let oldValue = index < oldParts.count ? oldParts[index] : 0
            if newValue != oldValue { return newValue > oldValue }
        }
        return false
    }

    // MARK: - Navigation helpers

    private func isOwnHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == Self.ownHost || host.hasSuffix("." + Self.ownHost)
    }

    private func isInternal(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "data" || scheme == "blob" { return true }
        return scheme == "https" && isOwnHost(url.host)
    }

    /// Google's sign-in hosts may load inside the app so the popup window can
    /// complete there instead of bouncing the user into Safari.
    private func isAuthHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["accounts.google.com", "accounts.google.co.uk", "accounts.youtube.com"].contains(host)
    }

    private func openExternally(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "mailto", "tel", "sms"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorPanel.isHidden = false
        progressBar.isHidden = true
    }

    // MARK: - Keyboard

    private func observeAuth() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nativeAuthCode(_:)),
            name: AppDelegate.authCodeNotification,
            object: nil
        )
    }

    @objc private func nativeAuthCode(_ note: Notification) {
        if let code = note.object as? String {
            finishNativeSignIn(code: code)
        }
    }

    private func observeKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        applyKeyboard(overlap, duration: duration)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        applyKeyboard(0, duration: duration)
    }

    private func applyKeyboard(_ overlap: CGFloat, duration: Double) {
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
            self.webViewBottom?.constant = -overlap
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Google sign-in (real browser session)

    private func startGoogleSignIn() {
        guard let url = URL(string: "https://vioa.site/auth/native?app=ios") else { return }
        authSession?.cancel()

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "vioaai") { [weak self] callback, error in
            guard let self = self else { return }
            defer { self.authSession = nil }
            if let error = error {
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                if !cancelled {
                    self.toast("تعذّر تسجيل الدخول · Sign-in failed")
                }
                return
            }
            guard let callback = callback,
                  let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false)
            else {
                self.toast("تعذّر تسجيل الدخول · Sign-in failed")
                return
            }
            if comps.queryItems?.first(where: { $0.name == "error" })?.value == "email" {
                self.focusEmailLogin()
                return
            }
            guard let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                self.toast("تعذّر تسجيل الدخول · Sign-in failed")
                return
            }
            self.finishNativeSignIn(code: code)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() {
            authSession = nil
            toast("تعذّر فتح المتصفح · Could not open the browser")
        }
    }

    private func finishNativeSignIn(code: String) {
        var comps = URLComponents(string: "https://vioa.site/auth/native/land")
        comps?.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "app", value: "ios"),
        ]
        if let url = comps?.url {
            webView.load(URLRequest(url: url))
        }
    }

    private func toast(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            alert.dismiss(animated: true)
        }
    }

    /// The user asked to finish signing in with email instead of Google.
    private func focusEmailLogin() {
        let js = """
        (function(){
          var email = document.getElementById('authEmail');
          var screen = document.getElementById('authScreen');
          if (screen) screen.classList.remove('hidden');
          if (email) {
            email.focus();
            if (email.scrollIntoView) email.scrollIntoView({ block: 'center', behavior: 'smooth' });
          }
          var err = document.getElementById('authError');
          if (err) err.textContent = '';
          return true;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func presentDownloadedFile(_ url: URL) {
        let size = DownloadStore.fileSizeString(at: url)
        let detail = size.isEmpty ? url.lastPathComponent : "\(url.lastPathComponent) · \(size)"
        let alert = UIAlertController(
            title: "تم التنزيل · Downloaded",
            message: "\(detail)\n\nFiles › On My iPhone › Vioa AI › Downloads",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "مشاركة · Share", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = share.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.maxY - 8, width: 1, height: 1)
            }
            self.present(share, animated: true)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        if isInternal(url) || isAuthHost(url.host) {
            decisionHandler(.allow)
            return
        }

        // Links with target="_blank" arrive here without a target frame.
        if navigationAction.targetFrame == nil,
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        openExternally(url)
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let downloadableExtensions: Set<String> = ["ipa", "apk", "exe", "msi", "dmg", "pkg", "zip", "rar", "7z"]
        if let filename = navigationResponse.response.suggestedFilename,
           downloadableExtensions.contains((filename as NSString).pathExtension.lowercased()) {
            decisionHandler(.download)
            return
        }

        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }

        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.contains("attachment") {
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorPanel.isHidden = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        errorPanel.isHidden = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        progressBar.isHidden = true
        errorPanel.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showError("تعذّر تحميل الصفحة.\nThe page could not be loaded.")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        refreshControl.endRefreshing()
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showError("لا يوجد اتصال بالإنترنت.\nNo internet connection.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: Downloads

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let existing = popup {
            existing.dismiss(animated: false)
            popup = nil
        }

        let controller = PopupWebViewController(configuration: configuration)
        controller.onClose = { [weak self] in
            self?.popup = nil
        }
        popup = controller
        present(controller, animated: true)
        return controller.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        popup?.dismiss(animated: true)
        popup = nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completionHandler(nil)
        })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Voice chat only needs the microphone, and only for our own site.
        if type == .microphone && isOwnHost(origin.host) {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    // MARK: - iOS 27 surface is installed by `appChromeScript` at document start.
}

// MARK: - Native bridge (web → app)

extension WebViewController: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "vioaAuth" else { return }
        var action = ""
        if let text = message.body as? String {
            action = text
        } else if let body = message.body as? [String: Any] {
            action = (body["action"] as? String) ?? ""
        }
        switch action {
        case "google":
            startGoogleSignIn()
        case "close":
            break
        default:
            break
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension WebViewController: ASWebAuthenticationPresentationContextProviding {

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window ?? UIWindow()
    }
}

// MARK: - WKDownloadDelegate

extension WebViewController: WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let destination = DownloadStore.destination(for: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let destination = downloadDestinations.removeValue(forKey: key) else { return }
        presentDownloadedFile(destination)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = UIAlertController(
            title: "فشل التنزيل · Download failed",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}
