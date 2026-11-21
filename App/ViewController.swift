import UIKit
import WebKit
import Network

// MARK: - Config

struct AppConfig {
    var url: URL?
    var themeColor: UIColor = .systemBlue
    var appearance: UIUserInterfaceStyle = .unspecified
    var showToolbar: Bool = true

    static func load() -> AppConfig {
        var cfg = AppConfig()
        guard let fileURL = Bundle.main.url(forResource: "Config", withExtension: "json"),
              let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cfg }

        if let s = obj["url"] as? String, !s.isEmpty, let u = URL(string: s) { cfg.url = u }
        if let s = obj["themeColor"] as? String, let c = UIColor(hex: s) { cfg.themeColor = c }
        switch (obj["appearance"] as? String)?.lowercased() {
        case "light": cfg.appearance = .light
        case "dark": cfg.appearance = .dark
        default: cfg.appearance = .unspecified
        }
        if let b = obj["showToolbar"] as? Bool { cfg.showToolbar = b }
        return cfg
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Error screen

final class ErrorView: UIView {
    var onRetry: (() -> Void)?
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(type: .system)

    init(accent: UIColor) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground

        icon.image = UIImage(systemName: "wifi.slash",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .light))
        icon.tintColor = accent
        icon.contentMode = .scaleAspectFit

        titleLabel.text = "Нет соединения"
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var conf = UIButton.Configuration.filled()
        conf.title = "Повторить"
        conf.baseBackgroundColor = accent
        conf.cornerStyle = .capsule
        conf.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 28, bottom: 12, trailing: 28)
        button.configuration = conf
        button.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(24, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message: String) {
        messageLabel.text = message
    }
}

// MARK: - Main controller

final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let config = AppConfig.load()

    private var webView: WKWebView!
    private let refresh = UIRefreshControl()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var errorView: ErrorView!
    private var toolbarView: UIView?
    private var backButton: UIButton?
    private var forwardButton: UIButton?
    private var observers: [NSKeyValueObservation] = []
    private let monitor = NWPathMonitor()
    private var failedURL: URL?
    private var errorVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = config.appearance
        view.backgroundColor = .systemBackground

        setupWebView()
        setupToolbar()
        setupProgress()
        setupErrorView()
        setupObservers()
        startNetworkMonitor()

        loadHome()
    }

    deinit { monitor.cancel() }

    // MARK: Setup

    private func setupWebView() {
        let wkConfig = WKWebViewConfiguration()
        wkConfig.allowsInlineMediaPlayback = true
        wkConfig.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: wkConfig)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        view.addSubview(webView)

        refresh.tintColor = config.themeColor
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    private func setupToolbar() {
        var bottomAnchor = view.bottomAnchor

        if config.showToolbar {
            let bar = UIView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blur.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(blur)

            let line = UIView()
            line.backgroundColor = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(line)

            let back = makeButton(symbol: "chevron.left") { [weak self] in self?.webView.goBack() }
            let forward = makeButton(symbol: "chevron.right") { [weak self] in self?.webView.goForward() }
            let home = makeButton(symbol: "house") { [weak self] in self?.loadHome() }
            let reloadBtn = makeButton(symbol: "arrow.clockwise") { [weak self] in self?.reloadOrRetry() }
            backButton = back
            forwardButton = forward

            let stack = UIStackView(arrangedSubviews: [back, forward, home, reloadBtn])
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
            view.addSubview(bar)

            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                blur.topAnchor.constraint(equalTo: bar.topAnchor),
                blur.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                blur.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                line.topAnchor.constraint(equalTo: bar.topAnchor),
                line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
                stack.topAnchor.constraint(equalTo: bar.topAnchor),
                stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                stack.heightAnchor.constraint(equalToConstant: 48),
                stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])
            toolbarView = bar
            bottomAnchor = bar.topAnchor
            updateNavButtons()
        }

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func makeButton(symbol: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol,
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)),
                   for: .normal)
        b.tintColor = config.themeColor
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }

    private func setupProgress() {
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = config.themeColor
        progress.trackTintColor = .clear
        progress.alpha = 0
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 3)
        ])
    }

    private func setupErrorView() {
        errorView = ErrorView(accent: config.themeColor)
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.reloadOrRetry() }
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
        ])
    }

    private func setupObservers() {
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            guard let self = self else { return }
            let value = Float(wv.estimatedProgress)
            self.progress.setProgress(value, animated: true)
            if value >= 1 {
                UIView.animate(withDuration: 0.3, delay: 0.2, options: []) { self.progress.alpha = 0 }
            } else {
                self.progress.alpha = 1
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            self?.updateNavButtons()
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            self?.updateNavButtons()
        })
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                if self?.errorVisible == true { self?.reloadOrRetry() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
    }

    private func updateNavButtons() {
        backButton?.isEnabled = webView.canGoBack
        forwardButton?.isEnabled = webView.canGoForward
    }

    // MARK: Loading

    private func loadHome() {
        hideError()
        if let url = config.url {
            webView.load(URLRequest(url: url))
        } else if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "site") {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
    }

    @objc private func reload() {
        reloadOrRetry()
        // the refresh control stops in the navigation callbacks
    }

    private func reloadOrRetry() {
        if errorVisible {
            hideError()
            if let url = failedURL ?? config.url {
                webView.load(URLRequest(url: url))
            } else {
                loadHome()
            }
        } else if webView.url == nil {
            loadHome()
        } else {
            webView.reload()
        }
    }

    private func showError(_ error: Error) {
        refresh.endRefreshing()
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        if let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL { failedURL = failing }
        let offline = ns.domain == NSURLErrorDomain &&
            (ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost)
        errorView.show(message: offline
                       ? "Проверь интернет. Страница загрузится сама, когда сеть появится."
                       : "Не удалось открыть страницу.\n\(ns.localizedDescription)")
        errorVisible = true
        errorView.isHidden = false
        progress.alpha = 0
    }

    private func hideError() {
        errorVisible = false
        errorView.isHidden = true
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hideError()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh.endRefreshing()
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    // MARK: WKUIDelegate

    // target="_blank" / window.open: open in the same web view
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(nil) })
        present(alert, animated: true)
    }
}
