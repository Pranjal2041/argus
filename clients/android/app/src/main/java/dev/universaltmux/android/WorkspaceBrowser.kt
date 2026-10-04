package dev.universaltmux.android

import android.content.Context
import android.graphics.Bitmap
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.*
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder

object WorkspaceLocators {
    private fun sensitive(key: String): Boolean {
        val key = key.lowercase().replace('-', '_')
        return key in listOf("code", "auth", "authorization", "session", "sessionid", "key", "api_key") ||
            listOf("token", "password", "secret", "credential").any(key::contains)
    }
    private fun safeQuery(query: String?) = query?.split('&').orEmpty().none { sensitive(URLDecoder.decode(it.substringBefore('='), "UTF-8")) }
    fun website(raw: String): JSONObject {
        val uri = URI(raw)
        require(uri.scheme?.lowercase() in listOf("http", "https") && !uri.host.isNullOrEmpty() &&
            uri.host.lowercase() !in listOf("localhost", "127.0.0.1", "::1", "[::1]") &&
            uri.userInfo == null && uri.fragment == null && safeQuery(uri.rawQuery)) {
            "Use a website URL without login parameters, or save this as a host service."
        }
        return JSONObject().put("kind", "website").put("url", raw)
    }
    fun service(brokerID: String, port: Int, path: String, scheme: String = "http"): JSONObject {
        val uri = URI("http://placeholder$path")
        require(brokerID.isNotEmpty() && port in 1..65535 && scheme in listOf("http", "https") &&
            path.startsWith('/') && !path.startsWith("//") && !path.contains('\n') && uri.fragment == null && safeQuery(uri.rawQuery)) {
            "A service needs a stable host, port, and path without login parameters."
        }
        return JSONObject().put("kind", "service").put("brokerID", brokerID).put("port", port).put("path", path).put("scheme", scheme)
    }
}

class WorkspaceBrowserSession(val id: String) {
    var view: WebView? = null
    var address by mutableStateOf("")
    var title by mutableStateOf("")
    var loading by mutableStateOf(false)
    var error by mutableStateOf<String?>(null)
    var canGoBack by mutableStateOf(false)
    var canGoForward by mutableStateOf(false)
    fun bind(context: Context, url: String): WebView {
        view?.let { return it }
        return WebView(context.applicationContext).also { web ->
            view = web
            web.settings.javaScriptEnabled = true
            web.settings.domStorageEnabled = true
            web.settings.allowFileAccess = false
            web.settings.allowContentAccess = true
            web.settings.setSupportZoom(true)
            web.settings.builtInZoomControls = true
            web.settings.displayZoomControls = false
            web.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    request.url.scheme?.lowercase() !in listOf("http", "https")
                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) { loading = true; error = null; address = url }
                override fun onPageFinished(view: WebView, url: String) {
                    loading = false; address = url; title = view.title.orEmpty()
                    canGoBack = view.canGoBack(); canGoForward = view.canGoForward()
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, failure: WebResourceError) {
                    if (request.isForMainFrame) { loading = false; error = failure.description.toString() }
                }
            }
            address = url; web.loadUrl(url)
        }
    }
    fun close() { view?.stopLoading(); view?.destroy(); view = null }
}
