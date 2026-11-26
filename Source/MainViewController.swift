import UIKit
import WebKit

/// 信达 ERP：一个 App 两个系统（ERP / 网站），原生顶部按钮 + 宫格入口来回切换。
/// ERP 数据源在服务器，本机只负责显示；网站是一个用户自定义的网址。
class MainViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    private var webView: WKWebView!

    // 老版本只存一个地址，升级后用它做迁移，不再作为日常读写键
    private let legacyServerURLKey = "xinda_erp_server_url"
    private let activeSlotKey = "xinda_erp_active_slot"
    private let customURLKey = "xinda_erp_url_custom"
    private let siteURLKey = "xinda_erp_site_url"

    /// 每个 ERP 服务器槽位各自记住自己的地址：改了云端地址后切到 ECS 再切回来，仍是改过的地址
    private struct ServerSlot {
        let name: String
        let key: String
        let fallback: String
    }
    private let slots: [ServerSlot] = [
        ServerSlot(name: "ECS 版", key: "xinda_erp_url_ecs", fallback: "http://116.62.39.220:3000"),
        ServerSlot(name: "云端版", key: "xinda_erp_url_cloud", fallback: "https://xinda-erp-14382.app.workbuddy.host"),
    ]

    // 两个系统用不同 UA：ERP 用桌面 UA + 移动版标识；网站用标准 iPhone UA 显示手机版
    private let erpUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 XindaMobileApp/1.0"
    private let siteUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 当前是否在网站系统。不持久化：每次冷启动强制回 ERP + ECS
    private var inSiteMode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        migrateLegacyURLIfNeeded()
        // 冷启动强制回 ECS（不记忆上次的槽位和系统）
        UserDefaults.standard.set(slots[0].key, forKey: activeSlotKey)
        inSiteMode = false
        setupNavigationBar()
        setupWebView()
        loadServer()
    }

    /// 老版本只有一个全局地址键；升级后把它归到对应槽位，避免用户改过的地址丢失
    private func migrateLegacyURLIfNeeded() {
        let d = UserDefaults.standard
        guard d.string(forKey: activeSlotKey) == nil,
              let old = d.string(forKey: legacyServerURLKey), !old.isEmpty else { return }
        if old.contains("116.62.39.220") {
            d.set(slots[0].key, forKey: activeSlotKey)
        } else {
            d.set(old, forKey: slots[1].key)
            d.set(slots[1].key, forKey: activeSlotKey)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
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
        title = ""
        let nav = navigationController?.navigationBar
        nav?.setBackgroundImage(UIImage(), for: .default)
        nav?.shadowImage = UIImage()
        nav?.isTranslucent = true
        nav?.prefersLargeTitles = false
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "网站", style: .plain, target: self, action: #selector(toggleSystem))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadPage)),
            UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings)),
        ]
        updateSystemButton()
    }

    private func updateSystemButton() {
        navigationItem.leftBarButtonItem?.title = inSiteMode ? "回 ERP" : "网站"
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
        webView.customUserAgent = erpUA
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - 系统切换

    @objc private func toggleSystem() {
        if inSiteMode {
            switchToERP()
        } else {
            switchToSite()
        }
    }

    private func switchToSite() {
        let saved = UserDefaults.standard.string(forKey: siteURLKey) ?? ""
        if saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showSiteURLInput()
            return
        }
        inSiteMode = true
        updateSystemButton()
        loadString(saved)
    }

    private func switchToERP() {
        inSiteMode = false
        updateSystemButton()
        loadServer()
    }

    // MARK: - 地址与加载

    private var activeSlot: ServerSlot? {
        let active = UserDefaults.standard.string(forKey: activeSlotKey) ?? slots[0].key
        return slots.first(where: { $0.key == active })
    }

    private var activeSlotName: String {
        activeSlot?.name ?? "自定义"
    }

    private func currentURL() -> String {
        let d = UserDefaults.standard
        if let slot = activeSlot {
            return d.string(forKey: slot.key) ?? slot.fallback
        }
        return d.string(forKey: customURLKey) ?? slots[0].fallback
    }

    private func loadServer() {
        webView.customUserAgent = erpUA
        loadString(currentURL())
    }

    private func loadString(_ text0: String) {
        var text = text0.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if inSiteMode {
            webView.customUserAgent = siteUA
            webView.reload()
        } else {
            loadServer()
        }
    }

    // MARK: - 设置

    @objc private func showSettings() {
        let sys = inSiteMode ? "网站" : "ERP【\(activeSlotName)】"
        let sheet = UIAlertController(
            title: "系统设置",
            message: "当前系统：\(sys)\n\(inSiteMode ? (UserDefaults.standard.string(forKey: siteURLKey) ?? "") : currentURL())",
            preferredStyle: .actionSheet
        )

        sheet.addAction(UIAlertAction(title: "系统切换（ERP ⇄ 网站）", style: .default) { [weak self] _ in
            self?.toggleSystem()
        })
        for slot in slots {
            let name = "ERP - \(slot.name)"
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                self?.selectSlot(slot)
            })
        }
        sheet.addAction(UIAlertAction(title: "自定义 ERP 地址…", style: .default) { [weak self] _ in
            self?.showCustomURLInput()
        })
        sheet.addAction(UIAlertAction(title: "设置网站地址…", style: .default) { [weak self] _ in
            self?.showSiteURLInput()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let pop = sheet.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItems?.last
        }
        present(sheet, animated: true)
    }

    /// 切换 ERP 槽位只改"当前用哪个"，不动各槽位已保存的地址
    private func selectSlot(_ slot: ServerSlot) {
        UserDefaults.standard.set(slot.key, forKey: activeSlotKey)
        if inSiteMode {
            inSiteMode = false
            updateSystemButton()
        }
        loadServer()
    }

    private func showCustomURLInput() {
        let alert = UIAlertController(
            title: "自定义 ERP 地址",
            message: "保存后将归入【\(activeSlotName)】，切走再切回仍用这个地址",
            preferredStyle: .alert
        )
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
            self?.saveCurrentSlotURL(text)
        })
        present(alert, animated: true)
    }

    private func showSiteURLInput() {
        let alert = UIAlertController(
            title: "网站地址",
            message: "输入你收藏的网站地址，点顶部「网站」即可打开",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = UserDefaults.standard.string(forKey: self.siteURLKey)
            field.placeholder = "https://example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并打开", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            UserDefaults.standard.set(text, forKey: self!.siteURLKey)
            self?.switchToSite()
        })
        present(alert, animated: true)
    }

    /// 自定义 ERP 地址写入当前槽位（这样改的就是"云端版"自己的地址，不会被默认值覆盖）
    private func saveCurrentSlotURL(_ url: String) {
        let d = UserDefaults.standard
        if let slot = activeSlot {
            d.set(url, forKey: slot.key)
        } else {
            d.set(url, forKey: customURLKey)
        }
        if inSiteMode {
            inSiteMode = false
            updateSystemButton()
        }
        loadServer()
    }

    // MARK: - 提示

    private func showMessage(_ message: String, title: String = "提示") {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: - WKNavigationDelegate

    /// 拦截网页里"网站"宫格按钮发出的 xinda://site 自定义协议，切到网站系统
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme?.lowercased() == "xinda" {
            switch url.host?.lowercased() ?? "" {
            case "site": switchToSite()
            case "erp": switchToERP()
            default: break
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isCancelledError(error) { return }
        showConnectError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isCancelledError(error) { return }
        showConnectError(error)
    }

    /// -999 = NSURLErrorCancelled：新导航开始或 stopLoading 时旧请求被取消，属于正常现象，不应弹"连接失败"
    private func isCancelledError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func showConnectError(_ error: Error) {
        let alert = UIAlertController(
            title: "连接失败",
            message: "\(error.localizedDescription)\n\n请检查网络，或到右上角\"设置\"更换服务器地址",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in self?.reloadPage() })
        alert.addAction(UIAlertAction(title: "设置", style: .default) { [weak self] _ in self?.showSettings() })
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
