import UIKit
import WebKit

/// 信达 ERP 在线版壳：WKWebView 加载服务器地址
/// 数据源在服务器，本机只负责显示，不存业务数据
class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!
    private let serverURLKey = "xinda_erp_server_url"

    // 预置服务器，可自行增减。第一个为默认。
    private let presetServers: [(name: String, url: String)] = [
        ("ECS 版", "http://116.62.39.220:3000"),
        ("云端版", "https://xinda-erp-14382.app.workbuddy.host"),
    ]

    private let defaultURL = "http://116.62.39.220:3000"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupNavigationBar()
        setupWebView()
        loadServer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 网页顶到状态栏下方，避免被状态栏遮挡；底部留出让 Home 指示条的空间
        let top = statusBarHeight()
        let bottom = view.safeAreaInsets.bottom
        let inset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if webView.scrollView.contentInset != inset {
            webView.scrollView.contentInset = inset
        }
    }

    private func statusBarHeight() -> CGFloat {
        if #available(iOS 13.0, *) {
            return view.window?.windowScene?.statusBarManager?.statusBarFrame.height ?? 44
        }
        return UIApplication.shared.statusBarFrame.height
    }

    // MARK: - UI

    private func setupNavigationBar() {
        // 透明导航栏：去掉原生标题，让网页自带的公司抬头顶到最上面，只留右侧按钮
        title = ""
        let nav = navigationController?.navigationBar
        nav?.setBackgroundImage(UIImage(), for: .default)
        nav?.shadowImage = UIImage()
        nav?.isTranslucent = true
        nav?.prefersLargeTitles = false
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadPage)),
            UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings)),
        ]
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 桌面 UA 打底避免业务表格错位，追加 XindaMobileApp 标识让服务端输出移动版外壳
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 XindaMobileApp/1.0"
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - 地址与加载

    private func currentURL() -> String {
        UserDefaults.standard.string(forKey: serverURLKey) ?? defaultURL
    }

    private func loadServer() {
        var text = currentURL().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            text = "http://" + text
        }
        guard let url = URL(string: text) else {
            showMessage("地址无效，请到右上角设置检查")
            return
        }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    @objc private func reloadPage() {
        loadServer()
    }

    // MARK: - 设置

    @objc private func showSettings() {
        let sheet = UIAlertController(title: "服务器设置", message: "选择预置地址或手动输入", preferredStyle: .actionSheet)

        for server in presetServers {
            sheet.addAction(UIAlertAction(title: server.name, style: .default) { [weak self] _ in
                self?.saveAndLoad(server.url)
            })
        }
        sheet.addAction(UIAlertAction(title: "自定义地址…", style: .default) { [weak self] _ in
            self?.showCustomURLInput()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let pop = sheet.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(sheet, animated: true)
    }

    private func showCustomURLInput() {
        let alert = UIAlertController(title: "自定义服务器地址", message: "例：http://116.62.39.220:3000", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.currentURL()
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并连接", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.saveAndLoad(text)
        })
        present(alert, animated: true)
    }

    private func saveAndLoad(_ url: String) {
        UserDefaults.standard.set(url, forKey: serverURLKey)
        loadServer()
    }

    // MARK: - 提示

    private func showMessage(_ message: String, title: String = "提示") {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showConnectError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showConnectError(error)
    }

    private func showConnectError(_ error: Error) {
        let alert = UIAlertController(
            title: "连接失败",
            message: "\(error.localizedDescription)\n\n请检查网络，或到右上角\"设置\"更换服务器地址",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in self?.loadServer() })
        alert.addAction(UIAlertAction(title: "设置地址", style: .default) { [weak self] _ in self?.showSettings() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - WKUIDelegate（处理 JS 的 alert/confirm）

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
