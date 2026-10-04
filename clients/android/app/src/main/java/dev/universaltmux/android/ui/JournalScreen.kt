package dev.universaltmux.android

import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

const val SCREEN_JOURNAL = 17
const val SCREEN_WRAPPED = 18

private class JournalNativeBridge(private val receive: (JSONObject) -> Unit) {
    @JavascriptInterface fun postMessage(text: String) { runCatching { receive(JSONObject(text)) } }
}

/** Only bundled, app-owned pages receive the bridge; external navigation is
 * disallowed. Both platforms use the same ledger and Wrapped renderers. */
@Composable
fun JournalScreen(vm: AppViewModel, wrapped: Boolean) {
    val coroutine = rememberCoroutineScope()
    var view by remember { mutableStateOf<WebView?>(null) }
    var ready by remember { mutableStateOf(false) }
    var day by rememberSaveable { mutableStateOf<String?>(null) }
    var period by rememberSaveable { mutableStateOf(0) }
    var issue by remember { mutableStateOf<String?>(null) }
    val rows = vm.workspace.collection("journal")
    val dayRows = rows.filter { it.data?.optString("kind") == "day" }
    fun send(function: String, data: JSONObject) { view?.evaluateJavascript("window.$function($data)", null) }
    suspend fun loadDay(requested: String) {
        val entries = vm.workspace.collection("journal").filter { it.data?.optString("day") == requested }
        val workspace = vm.workspace.workspaceID
        try {
            val text = withContext(Dispatchers.IO) { entries.joinToString("\n") { row ->
                vm.workspaceBlobs.download(vm.workspaceHost(), row.data!!.getString("hash")).readText()
            } }
            if (day == requested && workspace == vm.workspace.workspaceID) send("UTLedger.setDay", JSONObject().put("day", requested).put("jsonl", text))
            issue = null
        } catch (e: Exception) { issue = e.message }
    }
    LaunchedEffect(ready, wrapped, rows.map { it.revision }, period) {
        if (!ready) return@LaunchedEffect
        if (wrapped) {
            vm.workspace.data("journal", "wrapped")?.optJSONObject("periods")?.optJSONObject(period.toString())?.let { send("UTWrapped.setData", it) }
            vm.workspace.data("journal", "persona-$period")?.optJSONObject("persona")?.let { send("UTWrapped.setPersona", it) }
        } else {
            val days = dayRows.groupBy { it.data?.optString("day").orEmpty() }.toSortedMap(compareByDescending { it })
            val payload = JSONArray(days.map { (date, entries) -> JSONObject().put("day", date).put("count", entries.sumOf { it.data?.optLong("count") ?: 0L }) })
            send("UTLedger.setDays", JSONObject().put("days", payload).put("scope", vm.workspace.workspaceID).put("dir", "Shared workspace").put("selectedDay", day))
            day?.let { loadDay(it) }
        }
    }
    DisposableEffect(Unit) { onDispose { view?.removeJavascriptInterface("ArgusNative"); view?.destroy(); view = null } }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp)) {
            if (wrapped) listOf(0 to "All time", 7 to "Week", 30 to "Month", 90 to "Quarter", 365 to "Year").forEach { (days, label) ->
                FilterChip(period == days, { period = days }, label = { Text(label) }, modifier = Modifier.padding(end = 6.dp))
            }
            TextButton(onClick = { vm.refreshWorkspace(true); if (!wrapped) day?.let { coroutine.launch { loadDay(it) } } }) { Text("Refresh") }
            if (wrapped) TextButton(onClick = { vm.changeShared("commands", "wrapped-persona-$period", JSONObject().put("kind", "wrapped-persona").put("days", period)) }, enabled = vm.workspace.loaded && vm.workspace.data("commands", "wrapped-persona-$period") == null) { Text("Generate persona") }
        }
        (issue ?: vm.workspace.issue)?.let { Text(it, color = LocalTheme.current.waiting, modifier = Modifier.padding(12.dp)) }
        AndroidView(modifier = Modifier.weight(1f).fillMaxWidth(), factory = { context ->
            WebView(context).also { web ->
                view = web; web.settings.javaScriptEnabled = true; web.settings.allowFileAccess = false; web.settings.allowContentAccess = false
                web.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true
                }
                web.addJavascriptInterface(JournalNativeBridge { message ->
                    coroutine.launch(Dispatchers.Main) {
                        when (message.optString("type")) {
                            "ready" -> ready = true
                            "day" -> { day = message.optString("d"); day?.let { loadDay(it) } }
                            "refresh" -> { vm.refreshWorkspace(true); day?.let { loadDay(it) } }
                            "openArtifact" -> vm.requestArtifacts(message.optString("id"))
                        }
                    }
                }, "ArgusNative")
                web.loadUrl("file:///android_asset/${if (wrapped) "wrapped" else "ledger"}/index.html")
            }
        })
    }
}
