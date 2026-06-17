package dev.universaltmux.android

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Divider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView

/** A W&B run shown in place of the terminal. One WebView with the app-wide (persistent)
 *  CookieManager so the W&B login survives across runs + relaunches — mirrors the Mac. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WandbScreen(vm: AppViewModel, broker: Broker, session: String, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val th = LocalTheme.current
    val runs = vm.wandbFor(broker, session)
    val current = vm.currentWandbRun(broker, session)
    var menu by remember { mutableStateOf(false) }
    var webView by remember { mutableStateOf<WebView?>(null) }

    Column(Modifier.fillMaxSize().background(th.bg)) {
        androidx.compose.foundation.layout.Row(
            Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onClose) { Icon(Icons.Filled.Terminal, "Back to terminal", tint = th.text) }
            Box(Modifier.weight(1f)) {
                TextButton(onClick = { menu = true }) {
                    Text(current?.label ?: "W&B run", color = th.accent, fontSize = 14.sp, maxLines = 1)
                }
                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                    runs.reversed().forEach { r ->
                        DropdownMenuItem(text = { Text(r.label) }, onClick = { vm.setWandbCurrent(broker, session, r); menu = false })
                    }
                }
            }
            IconButton(onClick = { webView?.reload() }) { Icon(Icons.Filled.Refresh, "Reload", tint = th.dim) }
            IconButton(onClick = { current?.let { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it.url))) } }) {
                Icon(Icons.Filled.OpenInBrowser, "Open in browser", tint = th.dim)
            }
        }
        Divider(color = th.border)
        AndroidView(
            factory = { c ->
                CookieManager.getInstance().setAcceptCookie(true)
                WebView(c).apply {
                    CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    webViewClient = WebViewClient()
                    webView = this
                    current?.let { loadUrl(it.url) }
                }
            },
            update = { wv ->
                webView = wv
                current?.let { if (wv.url != it.url) wv.loadUrl(it.url) }
            },
            modifier = Modifier.weight(1f).fillMaxWidth(),
        )
    }
}
