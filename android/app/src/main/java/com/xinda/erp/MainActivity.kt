package com.xinda.erp

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.DialogInterface
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/**
 * 信达 ERP Android：一个 App 两个系统（ERP / 网站）。
 * 与 iOS 版 MainViewController 行为对齐：
 *  - 冷启动强制回 ERP + ECS，不记忆上次槽位/系统
 *  - 切到「网站」需密码 666，回 ERP 不设限
 *  - ERP 各服务器槽位地址独立记忆
 *  - 拦截 xinda://site / xinda://erp 自定义协议（网页宫格按钮）
 *  - ERP 用桌面 UA + XindaMobileApp/1.0；网站用手机 UA
 *  - 过滤导航取消错误（-999 等价），不误报"连接失败"
 */
class MainActivity : Activity() {

    companion object {
        private const val PREF = "xinda_erp_prefs"
        private const val LEGACY_URL_KEY = "xinda_erp_server_url"
        private const val ACTIVE_SLOT_KEY = "xinda_erp_active_slot"
        private const val CUSTOM_URL_KEY = "xinda_erp_url_custom"
        private const val SITE_URL_KEY = "xinda_erp_site_url"
        private const val SWITCH_PASSWORD = "666"

        // WebViewClient.ERROR_ABORTED = -1：导航被新请求取消（等同 iOS -999），非真实错误
        private const val ERROR_ABORTED = -1

        private const val ERP_UA =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 XindaMobileApp/1.0"
        private const val SITE_UA =
            "Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36"
    }

    private data class ServerSlot(val name: String, val key: String, val fallback: String)

    private val slots = listOf(
        ServerSlot("ECS 版", "xinda_erp_url_ecs", "http://116.62.39.220:3000"),
        ServerSlot("云端版", "xinda_erp_url_cloud", "https://xinda-erp-14382.app.workbuddy.host"),
    )

    private lateinit var webView: WebView
    private lateinit var btnLeft: TextView
    private var inSiteMode = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        migrateLegacyUrlIfNeeded()
        // 冷启动强制回 ECS
        prefs().edit().putString(ACTIVE_SLOT_KEY, slots[0].key).apply()
        inSiteMode = false

        buildUI()
        loadServer()
    }

    private fun prefs() = getSharedPreferences(PREF, Context.MODE_PRIVATE)

    // ------------------------------------------------------------------ UI
    private fun buildUI() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            setBackgroundColor(Color.parseColor("#F2F4F8"))
        }

        // 顶部条：左「切换」+ 右「刷新 / 设置」
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#1E6BFF"))
            val h = (52 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, h)
            setPadding(dp(10), 0, dp(6), 0)
        }

        btnLeft = navButton("切换").also { bar.addView(it) }

        val spacer = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(0, 1, 1f)
        }
        bar.addView(spacer)
        bar.addView(navButton("刷新").also { it.setOnClickListener { reloadPage() } })
        bar.addView(navButton("设置").also { it.setOnClickListener { showSettings() } })

        root.addView(bar)

        webView = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        setupWebView()
        root.addView(webView)
        setContentView(root)
        updateSystemButton()
    }

    private fun navButton(text: String) = TextView(this).apply {
        this.text = text
        setTextColor(Color.WHITE)
        textSize = 16f
        gravity = Gravity.CENTER
        isClickable = true
        val p = (10 * resources.displayMetrics.density).toInt()
        val v = (8 * resources.displayMetrics.density).toInt()
        setPadding(p, v, p, v)
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    private fun dp(n: Int) = (n * resources.displayMetrics.density).toInt()

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            javaScriptCanOpenWindowsAutomatically = true
            loadsImagesAutomatically = true
            loadWithOverviewMode = true
            useWideViewPort = true
            cacheMode = WebSettings.LOAD_NO_CACHE
            userAgentString = ERP_UA
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            }
        }
        webView.setLayerType(View.LAYER_TYPE_HARDWARE, null)

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                return handleUrl(url)
            }

            @SuppressLint("NewApi")
            override fun shouldOverrideUrlLoading(
                view: WebView?, request: WebResourceRequest?): Boolean {
                return handleUrl(request?.url?.toString())
            }

            private fun handleUrl(url: String?): Boolean {
                if (url.isNullOrBlank()) return false
                val uri = try { Uri.parse(url) } catch (_: Exception) { return false }
                if (uri.scheme?.lowercase() == "xinda") {
                    when (uri.host?.lowercase() ?: "") {
                        "site" -> switchToSite()
                        "erp" -> switchToERP()
                    }
                    return true
                }
                return false
            }

            override fun onReceivedError(
                view: WebView?, errorCode: Int, description: String?, failingUrl: String?) {
                // Android 的 ERROR_ABORTED(-1) 对应 iOS -999：导航被新请求取消，属正常现象
                if (errorCode == ERROR_ABORTED) return
                showConnectError(description ?: "未知错误")
            }

            @SuppressLint("NewApi")
            override fun onReceivedError(
                view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                if (error == null) return
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                    error.errorCode == ERROR_ABORTED) return
                showConnectError(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                        error.description.toString() else "连接失败")
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onJsAlert(
                view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                messageDialog(message ?: "", "提示") { result?.confirm() }
                return true
            }

            override fun onJsConfirm(
                view: WebView?, url: String?, message: String?, result: JsResult?): Boolean {
                confirmDialog(message ?: "", onOk = { result?.confirm() },
                    onCancel = { result?.cancel() })
                return true
            }

            override fun onJsPrompt(
                view: WebView?, url: String?, message: String?, defaultValue: String?,
                result: JsPromptResult?): Boolean {
                val input = EditText(this@MainActivity).apply {
                    inputType = InputType.TYPE_CLASS_TEXT
                    setText(defaultValue ?: "")
                }
                AlertDialog.Builder(this@MainActivity)
                    .setTitle("输入")
                    .setMessage(message ?: "")
                    .setView(input)
                    .setPositiveButton("确定") { _, _ -> result?.confirm(input.text.toString()) }
                    .setNegativeButton("取消") { _, _ -> result?.cancel() }
                    .setOnCancelListener { result?.cancel() }
                    .show()
                return true
            }

            // target=_blank 等新窗口：直接在本 WebView 打开，避免空白页
            override fun onCreateWindow(
                view: WebView?, isDialog: Boolean, isUserGesture: Boolean,
                resultMsg: android.os.Message?): Boolean {
                val transport = resultMsg?.obj as? WebView.WebViewTransport ?: return false
                transport.webView = webView
                resultMsg.sendToTarget()
                return true
            }
        }
    }

    // ---------------------------------------------------------- 系统切换
    private fun updateSystemButton() {
        btnLeft.text = if (inSiteMode) "回 ERP" else "切换"
    }

    private fun toggleSystem() {
        if (inSiteMode) switchToERP() else switchToSite()
    }

    private fun switchToSite() {
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            gravity = Gravity.CENTER
            hint = "切换密码"
        }
        AlertDialog.Builder(this)
            .setTitle("系统切换")
            .setMessage("请输入切换密码")
            .setView(input)
            .setNegativeButton("取消", null)
            .setPositiveButton("确定") { _, _ ->
                if (input.text.toString() != SWITCH_PASSWORD) {
                    messageDialog("密码错误，无法切换", "切换已取消")
                } else {
                    performSiteSwitch()
                }
            }
            .show()
    }

    private fun performSiteSwitch() {
        val saved = prefs().getString(SITE_URL_KEY, "").orEmpty()
        if (saved.trim().isEmpty()) {
            showSiteUrlInput(autoSwitch = true)
            return
        }
        inSiteMode = true
        updateSystemButton()
        webView.settings.userAgentString = SITE_UA
        loadString(saved)
    }

    private fun switchToERP() {
        inSiteMode = false
        updateSystemButton()
        loadServer()
    }

    // ------------------------------------------------------------ 地址加载
    private fun activeSlot(): ServerSlot? {
        val active = prefs().getString(ACTIVE_SLOT_KEY, slots[0].key)
        return slots.firstOrNull { it.key == active }
    }

    private fun activeSlotName() = activeSlot()?.name ?: "自定义"

    private fun currentURL(): String {
        val slot = activeSlot()
        return if (slot != null) {
            prefs().getString(slot.key, slot.fallback) ?: slot.fallback
        } else {
            prefs().getString(CUSTOM_URL_KEY, slots[0].fallback) ?: slots[0].fallback
        }
    }

    private fun loadServer() {
        webView.settings.userAgentString = ERP_UA
        loadString(currentURL())
    }

    private fun loadString(text0: String) {
        var text = text0.trim()
        if (!text.startsWith("http://") && !text.startsWith("https://")) {
            text = "http://$text"
        }
        val uri = try { Uri.parse(text) } catch (_: Exception) { null }
        if (uri?.host.isNullOrBlank()) {
            toast("地址无效，请到右上角设置检查")
            return
        }
        webView.loadUrl(text)
    }

    private fun reloadPage() {
        if (inSiteMode) {
            webView.settings.userAgentString = SITE_UA
            webView.reload()
        } else {
            loadServer()
        }
    }

    // ---------------------------------------------------------------- 设置
    private fun showSettings() {
        val sys = if (inSiteMode) "网站" else "ERP【${activeSlotName()}】"
        val cur = if (inSiteMode) {
            prefs().getString(SITE_URL_KEY, "").orEmpty()
        } else {
            currentURL()
        }
        val labels = mutableListOf<String>().apply {
            add("系统切换（ERP ⇄ 网站）")
            slots.forEach { add("ERP - ${it.name}") }
            add("自定义 ERP 地址…")
            add("设置网站地址…")
            add("取消")
        }
        AlertDialog.Builder(this)
            .setTitle("系统设置")
            .setMessage("当前系统：$sys\n$cur")
            .setAdapter(ArrayAdapter(this, android.R.layout.simple_list_item_1, labels)) { _, i ->
                when {
                    i == 0 -> toggleSystem()
                    i in 1..slots.size -> selectSlot(slots[i - 1])
                    i == slots.size + 1 -> showCustomURLInput()
                    i == slots.size + 2 -> showSiteUrlInput(autoSwitch = false)
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun selectSlot(slot: ServerSlot) {
        prefs().edit().putString(ACTIVE_SLOT_KEY, slot.key).apply()
        if (inSiteMode) {
            inSiteMode = false
            updateSystemButton()
        }
        loadServer()
    }

    private fun showCustomURLInput() {
        val input = EditText(this).apply {
            setText(currentURL())
            inputType = InputType.TYPE_TEXT_VARIATION_URI
        }
        AlertDialog.Builder(this)
            .setTitle("自定义 ERP 地址")
            .setMessage("保存后将归入【${activeSlotName()}】，切走再切回仍用这个地址")
            .setView(input)
            .setNegativeButton("取消", null)
            .setPositiveButton("保存并连接") { _, _ ->
                val text = input.text.toString()
                if (text.trim().isNotEmpty()) saveCurrentSlotURL(text)
            }
            .show()
    }

    private fun showSiteUrlInput(autoSwitch: Boolean) {
        val input = EditText(this).apply {
            setText(prefs().getString(SITE_URL_KEY, "").orEmpty())
            hint = "https://example.com"
            inputType = InputType.TYPE_TEXT_VARIATION_URI
        }
        AlertDialog.Builder(this)
            .setTitle("网站地址")
            .setMessage(if (autoSwitch) "首次使用，请输入你收藏的网站地址"
                        else "输入你收藏的网站地址；保存后点顶部「切换」进入")
            .setView(input)
            .setNegativeButton("取消", null)
            .setPositiveButton(if (autoSwitch) "保存并切换" else "保存") { _, _ ->
                val text = input.text.toString()
                if (text.trim().isEmpty()) return@setPositiveButton
                prefs().edit().putString(SITE_URL_KEY, text).apply()
                if (autoSwitch) performSiteSwitch()
            }
            .show()
    }

    private fun saveCurrentSlotURL(url: String) {
        val slot = activeSlot()
        if (slot != null) {
            prefs().edit().putString(slot.key, url).apply()
        } else {
            prefs().edit().putString(CUSTOM_URL_KEY, url).apply()
        }
        if (inSiteMode) {
            inSiteMode = false
            updateSystemButton()
        }
        loadServer()
    }

    // ------------------------------------------------------------ 老版迁移
    private fun migrateLegacyUrlIfNeeded() {
        if (prefs().contains(ACTIVE_SLOT_KEY)) return
        val old = prefs().getString(LEGACY_URL_KEY, "").orEmpty()
        if (old.isEmpty()) return
        if (old.contains("116.62.39.220")) {
            prefs().edit().putString(ACTIVE_SLOT_KEY, slots[0].key).apply()
        } else {
            prefs().edit()
                .putString(slots[1].key, old)
                .putString(ACTIVE_SLOT_KEY, slots[1].key)
                .apply()
        }
    }

    // -------------------------------------------------------------- 提示框
    private fun messageDialog(msg: String, title: String = "提示", onOk: (() -> Unit)? = null) {
        AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(msg)
            .setPositiveButton("好") { _, _ -> onOk?.invoke() }
            .show()
    }

    private fun confirmDialog(msg: String, onOk: () -> Unit, onCancel: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle("确认")
            .setMessage(msg)
            .setPositiveButton("确定") { _, _ -> onOk() }
            .setNegativeButton("取消") { _, _ -> onCancel() }
            .setOnCancelListener { onCancel() }
            .show()
    }

    private fun showConnectError(msg: String) {
        AlertDialog.Builder(this)
            .setTitle("连接失败")
            .setMessage("$msg\n\n请检查网络，或到右上角\"设置\"更换服务器地址")
            .setPositiveButton("重试") { _, _ -> reloadPage() }
            .setNeutralButton("设置") { _, _ -> showSettings() }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun toast(msg: String) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && webView.canGoBack()) {
            webView.goBack()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
