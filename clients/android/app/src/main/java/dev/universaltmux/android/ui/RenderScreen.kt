package dev.universaltmux.android

import android.annotation.SuppressLint
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONObject

/** The live terminal for the currently shown session — lets the top bar
 *  (Render, Find) reach the visible RemoteTerminal without re-plumbing. */
object ActiveTerm {
    var rt: RemoteTerminal? = null
}

/**
 * "Renders" (ported from the Mac): the terminal's markdown/LaTeX/code, typeset
 * properly in a full-screen overlay. Same OFFLINE bundle (assets/render:
 * marked + KaTeX + highlight.js) and the same extraction contract — a static
 * snapshot; the live terminal underneath is never touched.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun RenderOverlay(text: String, onClose: () -> Unit) {
    var fontSize by remember { mutableStateOf(16) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val paper = Color(0xFFFBFBFA)

    fun push(wv: WebView, px: Int) {
        wv.evaluateJavascript("window.UTRender.set(${JSONObject.quote(text)}, $px)", null)
    }

    Column(Modifier.fillMaxSize().background(paper)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Render", color = Color(0xFF1F2328), fontSize = 15.sp)
            Spacer(Modifier.width(8.dp))
            Text("markdown · LaTeX · code", color = Color(0xFF6E7681), fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            ZoomButton("−") { fontSize = (fontSize - 1).coerceAtLeast(9); webView?.let { push(it, fontSize) } }
            Text("$fontSize", color = Color(0xFF6E7681), fontSize = 12.sp, modifier = Modifier.padding(horizontal = 6.dp))
            ZoomButton("+") { fontSize = (fontSize + 1).coerceAtMost(28); webView?.let { push(it, fontSize) } }
            IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close", tint = Color(0xFF6E7681)) }
        }
        AndroidView(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = true
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            push(view, fontSize)
                        }
                    }
                    loadUrl("file:///android_asset/render/index.html")
                    webView = this
                }
            },
        )
    }
}

@Composable
private fun ZoomButton(label: String, onClick: () -> Unit) {
    Box(
        Modifier.size(28.dp).background(Color(0x14000000), RoundedCornerShape(6.dp)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(label, color = Color(0xFF57606A), fontSize = 16.sp) }
}
