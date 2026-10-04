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
import androidx.compose.material3.TextButton
import kotlinx.coroutines.launch
import java.io.File

/** The live terminal for the currently shown session — lets the top bar
 *  (Render, Find) reach the visible RemoteTerminal without re-plumbing. */
object ActiveTerm {
    var rt: RemoteTerminal? = null
}

data class RenderContent(
    val id: Long,
    val text: String,
    val sourceOrigin: String,
    val terminalText: String = text,
    val panel: JSONObject = JSONObject(),
    val brokerID: String? = null,
)

/**
 * "Renders" (ported from the Mac): the terminal's markdown/LaTeX/code, typeset
 * properly in a full-screen overlay. Same OFFLINE bundle (assets/render:
 * marked + KaTeX + highlight.js) and the same authored-source contract as Mac,
 * with captured terminal text as the immediate fallback. The live terminal
 * underneath is never touched.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun RenderOverlay(document: RenderContent, onClose: () -> Unit, vm: AppViewModel? = null) {
    var fontSize by remember { mutableStateOf(16) }
    var webView by remember { mutableStateOf<WebView?>(null) }
    val paper = Color(0xFFFBFBFA)
    val scope = rememberCoroutineScope()
    var saving by remember { mutableStateOf(false) }
    var issue by remember { mutableStateOf<String?>(null) }
    var ready by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { onDispose { webView?.destroy(); webView = null } }

    fun push(wv: WebView, px: Int) {
        wv.evaluateJavascript("window.UTRender.set(${JSONObject.quote(document.text)}, $px)", null)
    }

    Column(Modifier.fillMaxSize().background(paper)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Render", color = Color(0xFF1F2328), fontSize = 15.sp)
            Spacer(Modifier.width(8.dp))
            Text(
                if (document.sourceOrigin.endsWith("-transcript")) "Markdown · LaTeX · tables · code"
                else "rendered terminal fallback",
                color = Color(0xFF6E7681), fontSize = 11.sp, modifier = Modifier.weight(1f), maxLines = 2,
            )
            ZoomButton("−", !saving) { fontSize = (fontSize - 1).coerceAtLeast(9); webView?.let { push(it, fontSize) } }
            Text("$fontSize", color = Color(0xFF6E7681), fontSize = 12.sp, modifier = Modifier.padding(horizontal = 6.dp))
            ZoomButton("+", !saving) { fontSize = (fontSize + 1).coerceAtMost(28); webView?.let { push(it, fontSize) } }
            IconButton(onClick = onClose, enabled = !saving) { Icon(Icons.Filled.Close, "Close", tint = Color(0xFF6E7681)) }
        }
        if (vm != null) Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(enabled = ready && !saving && vm.workspace.loaded, onClick = {
                val web = webView ?: return@TextButton
                saving = true; issue = null
                scope.launch {
                    val file = File.createTempFile("argus-render", ".pdf", web.context.cacheDir)
                    try {
                        renderPDF(web, file)
                        vm.artifactTransfers.stage(file.inputStream(), "Render.pdf", "application/pdf", document.panel,
                            document.brokerID, kind = "render-pdf", source = renderSourceArchive(document, fontSize))
                        vm.refreshArtifactTransfers(); issue = "Saved to artifacts"
                    } catch (e: Exception) { issue = e.message }
                    finally { file.delete(); saving = false }
                }
            }) { Text(if (saving) "Saving…" else "Save PDF + source") }
            issue?.let { Text(it, color = Color(0xFF6E7681), fontSize = 11.sp) }
        }
        AndroidView(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            factory = { ctx ->
                WebView(ctx).apply {
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = true
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            push(view, fontSize); ready = true
                        }
                    }
                    loadUrl("file:///android_asset/render/index.html")
                    webView = this
                }
            },
            // Re-push when the immediate terminal fallback is upgraded to the
            // screen-matched transcript; AndroidView otherwise retains the
            // original factory closure for the lifetime of this overlay.
            update = { view ->
                view.setOnTouchListener { _, _ -> saving }
                if (!saving) push(view, fontSize)
            },
        )
    }
}

@Composable
private fun ZoomButton(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        Modifier.size(28.dp).background(Color(0x14000000), RoundedCornerShape(6.dp)).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(label, color = Color(0xFF57606A), fontSize = 16.sp) }
}
