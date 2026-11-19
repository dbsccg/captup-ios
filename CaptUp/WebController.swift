import UIKit
import WebKit
import QuickLook

/// Adresses du portail Capt'Up.
enum Portal {
    static let host = "dbsconseil.fr"
    static let start = URL(string: "https://dbsconseil.fr/portail-dbs-conseil.html?app=ios")!

    static func isPortalHost(_ h: String) -> Bool {
        let x = h.lowercased()
        return x == host || x == "www." + host
    }

    /// Vrai pour les pages du portail (et les pages internes : about, blob, data).
    static func isInternal(_ url: URL?) -> Bool {
        guard let url = url else { return true }
        let s = (url.scheme ?? "").lowercased()
        if s.isEmpty || s == "about" || s == "blob" || s == "data" { return true }
        guard s == "http" || s == "https" else { return false }
        return isPortalHost(url.host ?? "")
    }

    static let background = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
            : UIColor(red: 246 / 255, green: 243 / 255, blue: 240 / 255, alpha: 1)
    }
}

/// Reçoit la demande d'impression envoyée par la page (window.print).
final class PrintBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "captupPrint", let wv = message.webView else { return }
        WebController.printContent(of: wv)
    }
}

final class WebController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    let webView: WKWebView
    private let isPopup: Bool
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var closeAfterDownload = false
    private var errorView: UIView?
    private let refresh = UIRefreshControl()

    // MARK: Configuration

    static func mainConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = []
        c.applicationNameForUserAgent = "CaptUp-iOS/1.0"
        let js = "window.print=function(){try{window.webkit.messageHandlers.captupPrint.postMessage(1);}catch(e){}};"
        c.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        c.userContentController.add(PrintBridge(), name: "captupPrint")
        return c
    }

    init(configuration: WKWebViewConfiguration, popup: Bool) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.isPopup = popup
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non utilisé")
    }

    // MARK: Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Portal.background
        webView.isOpaque = false
        webView.backgroundColor = Portal.background
        webView.scrollView.backgroundColor = Portal.background
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: g.topAnchor),
            webView.bottomAnchor.constraint(equalTo: g.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        if isPopup {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Fermer", style: .done, target: self, action: #selector(closeSelf))
            navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "printer"), style: .plain, target: self, action: #selector(printSelf))
        } else {
            webView.allowsBackForwardNavigationGestures = true
            refresh.addTarget(self, action: #selector(reloadPage), for: .valueChanged)
            webView.scrollView.refreshControl = refresh
            webView.load(URLRequest(url: Portal.start))
        }
    }

    @objc private func closeSelf() {
        dismiss(animated: true)
    }

    @objc private func printSelf() {
        WebController.printContent(of: webView)
    }

    @objc private func reloadPage() {
        hideError()
        if webView.url == nil {
            webView.load(URLRequest(url: Portal.start))
        } else {
            webView.reload()
        }
    }

    private var topController: UIViewController {
        var t: UIViewController = self
        while let p = t.presentedViewController, !p.isBeingDismissed { t = p }
        return t
    }

    static func printContent(of wv: WKWebView) {
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = (wv.title?.isEmpty == false) ? wv.title! : "Capt'Up"
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info
        pc.printFormatter = wv.viewPrintFormatter()
        pc.present(animated: true, completionHandler: nil)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "mailto" || scheme == "tel" || scheme == "sms" {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // Les sites extérieurs (URSSAF, impots.gouv…) s'ouvrent dans Safari.
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if mainFrame && !Portal.isInternal(url) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let r = navigationResponse.response as? HTTPURLResponse,
           let cd = r.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh.endRefreshing()
        if isPopup { title = webView.title }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refresh.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refresh.endRefreshing()
        let e = error as NSError
        if e.code == NSURLErrorCancelled || e.domain == "WebKitErrorDomain" { return }
        if !isPopup { showError() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: Écran hors connexion

    private func showError() {
        guard errorView == nil else { return }
        let box = UIView()
        box.backgroundColor = Portal.background
        box.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Connexion impossible.\nVérifiez votre accès à Internet, puis réessayez."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label

        let button = UIButton(type: .system)
        button.setTitle("Réessayer", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        view.addSubview(box)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: view.topAnchor),
            box.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            box.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -32)
        ])
        errorView = box
    }

    private func hideError() {
        errorView?.removeFromSuperview()
        errorView = nil
    }

    // MARK: Nouvelles fenêtres (aperçus, documents)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url, !Portal.isInternal(u) {
            UIApplication.shared.open(u)
            return nil
        }
        let popup = WebController(configuration: configuration, popup: true)
        popup.loadViewIfNeeded()
        let nav = UINavigationController(rootViewController: popup)
        nav.modalPresentationStyle = .pageSheet
        topController.present(nav, animated: true)
        return popup.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if isPopup { dismiss(animated: true) }
    }

    // MARK: Appareil photo et micro

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(Portal.isPortalHost(origin.host) ? .grant : .prompt)
    }

    // MARK: Fenêtres de dialogue de la page

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topController.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        topController.present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Annuler", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { [weak a] _ in completionHandler(a?.textFields?.first?.text ?? "") })
        topController.present(a, animated: true)
    }

    // MARK: Téléchargements

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if isPopup { closeAfterDownload = true }
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "document" : suggestedFilename
        let url = dir.appendingPathComponent(name)
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if isPopup && closeAfterDownload, let host = presentingViewController {
            dismiss(animated: true) {
                WebController.preview(url, from: host)
            }
        } else {
            WebController.preview(url, from: topController)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        let a = UIAlertController(title: "Téléchargement impossible", message: error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        topController.present(a, animated: true)
    }

    // MARK: Aperçu du fichier téléchargé (avec partage et enregistrement)

    private static var previewHolder: PreviewSource?

    static func preview(_ url: URL, from host: UIViewController) {
        let source = PreviewSource(url: url)
        previewHolder = source
        let ql = QLPreviewController()
        ql.dataSource = source
        var t = host
        while let p = t.presentedViewController, !p.isBeingDismissed { t = p }
        t.present(ql, animated: true)
    }
}

final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as NSURL
    }
}
