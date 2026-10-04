package dev.universaltmux.android

import android.net.Uri
import android.view.ViewGroup
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.UUID

const val SCREEN_DASHBOARDS = 14
const val SCREEN_NOTEBOOKS = 15

@Composable
fun WorkspaceCatalogScreen(vm: AppViewModel, notebooks: Boolean) {
    val collection = if (notebooks) "notebooks" else "dashboards"
    val title = if (notebooks) "Notebooks" else "Dashboards"
    val records = vm.workspace.collection(collection).sortedBy { it.data?.optString("name").orEmpty() }
    var active by rememberSaveable(collection, vm.workspace.workspaceID) { mutableStateOf<String?>(null) }
    LaunchedEffect(vm.requestedDashboardID) {
        if (!notebooks && vm.requestedDashboardID != null) { active = vm.requestedDashboardID; vm.consumeDashboardRequest() }
    }
    var editing by remember { mutableStateOf<WorkspaceRecord?>(null) }
    var adding by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<WorkspaceRecord?>(null) }
    var query by rememberSaveable(collection) { mutableStateOf("") }
    val selected = records.firstOrNull { it.id == active }
    if (selected != null) {
        WorkspaceBrowserView(vm, selected, notebooks) { active = null }
    } else {
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, fontSize = 25.sp, color = LocalTheme.current.text, modifier = Modifier.weight(1f))
                    Button(onClick = { adding = true }, enabled = vm.workspace.loaded) { Text("Add") }
                }
                Text(if (notebooks) "Your workspace's notebooks, running on their own hosts" else "Websites and host services across your workspace", color = LocalTheme.current.dim, fontSize = 12.sp)
                (vm.workspaceSelectionIssue ?: vm.workspace.issue)?.let { Text(it, color = LocalTheme.current.waiting) }
            }
            item { OutlinedTextField(query, { query = it }, label = { Text("Search $title") }, modifier = Modifier.fillMaxWidth()) }
            if (records.isEmpty()) item { Text("No shared ${title.lowercase()} yet", color = LocalTheme.current.dim) }
            items(records.filter { it.data?.toString()?.contains(query, true) == true }, key = { it.id }) { record ->
                val data = record.data ?: JSONObject()
                val host = vm.brokers.firstOrNull { it.brokerID == data.optString("brokerID") }
                Card(Modifier.fillMaxWidth().clickable { active = record.id }) {
                    Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(data.optString("name", title), fontSize = 18.sp)
                        Text(if (data.optString("kind") == "website") data.optString("url") else "${host?.name ?: "Host offline"} · ${data.optString("path", "/")}${if (data.has("port")) " :${data.optInt("port")}" else ""}", fontSize = 12.sp)
                        Row {
                            TextButton(onClick = { active = record.id }) { Text("Open") }
                            TextButton(onClick = { editing = record }) { Text("Edit") }
                            TextButton(onClick = { deleting = record }) { Text("Remove") }
                        }
                    }
                }
            }
        }
    }
    if (adding || editing != null) CatalogEditor(vm, collection, notebooks, editing) { adding = false; editing = null }
    deleting?.let { row -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Remove ${row.data?.optString("name") ?: title} from the workspace?") },
        text = { Text("This removes the shared entry; files and running services remain on their host.") },
        confirmButton = { TextButton(onClick = { vm.changeShared(collection, row.id, null, true); vm.workspaceBrowser(row.id).close(); deleting = null }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } }) }
}

@Composable
private fun CatalogEditor(vm: AppViewModel, collection: String, notebooks: Boolean, record: WorkspaceRecord?, close: () -> Unit) {
    val original = record?.data ?: JSONObject()
    var name by remember { mutableStateOf(original.optString("name")) }
    var website by remember { mutableStateOf(!notebooks && original.optString("kind", "website") == "website") }
    var url by remember { mutableStateOf(original.optString("url", "https://")) }
    var path by remember { mutableStateOf(original.optString("path", "/")) }
    var port by remember { mutableStateOf(original.optInt("port", 8080).toString()) }
    var brokerID by remember { mutableStateOf(vm.brokers.firstOrNull { it.brokerID == original.optString("brokerID") }?.id ?: vm.selected?.first?.id) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = close, title = { Text(if (record == null) "Add ${if (notebooks) "notebook" else "dashboard"}" else "Edit shared entry") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
            if (!notebooks) Row { FilterChip(website, { website = true }, label = { Text("Website") }); Spacer(Modifier.width(6.dp)); FilterChip(!website, { website = false }, label = { Text("Host service") }) }
            if (website) OutlinedTextField(url, { url = it }, label = { Text("Website URL") }, modifier = Modifier.fillMaxWidth())
            else {
                BrokerPicker(vm.brokers.filter { it.brokerID.isNotEmpty() }, brokerID) { brokerID = it.id }
                OutlinedTextField(path, { path = it }, label = { Text(if (notebooks) "Notebook folder on host" else "Service path") }, modifier = Modifier.fillMaxWidth())
                if (!notebooks) OutlinedTextField(port, { port = it }, label = { Text("Port") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            error?.let { Text(it, color = LocalTheme.current.waiting) }
        }
    }, confirmButton = { TextButton(onClick = {
        try {
            require(name.isNotBlank()) { "Enter a name" }
            val host = vm.brokers.firstOrNull { it.id == brokerID }
            val locator = when {
                notebooks -> { require(host != null && host.brokerID.isNotEmpty() && path.isNotBlank()) { "Choose a connected host and folder" }; JSONObject().put("brokerID", host!!.brokerID).put("path", path) }
                website -> WorkspaceLocators.website(url)
                else -> WorkspaceLocators.service(host?.brokerID.orEmpty(), port.toIntOrNull() ?: 0, path)
            }
            // Preserve fields introduced by other clients, but remove fields of
            // the old locator kind when its transport changes.
            val data = JSONObject(original.toString())
            listOf("kind", "url", "brokerID", "port", "path", "scheme").forEach(data::remove)
            locator.keys().forEach { data.put(it, locator.get(it)) }; data.put("name", name.trim())
            vm.changeShared(collection, record?.id ?: UUID.randomUUID().toString(), data); close()
        } catch (e: Exception) { error = e.message }
    }) { Text("Save") } }, dismissButton = { TextButton(onClick = close) { Text("Cancel") } })
}

@Composable
private fun WorkspaceBrowserView(vm: AppViewModel, record: WorkspaceRecord, notebooks: Boolean, close: () -> Unit) {
    val browser = vm.workspaceBrowser(record.id)
    val data = record.data ?: JSONObject()
    var resolvedURL by remember(record.id) { mutableStateOf(browser.view?.url) }
    var resolving by remember(record.id) { mutableStateOf(false) }
    var attempt by remember { mutableStateOf(0) }
    var fileCallback by remember { mutableStateOf<ValueCallback<Array<Uri>>?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { files -> fileCallback?.onReceiveValue(files.toTypedArray()); fileCallback = null }
    DisposableEffect(Unit) { onDispose { fileCallback?.onReceiveValue(null); fileCallback = null } }
    LaunchedEffect(record.id, attempt) {
        if (browser.view != null && attempt == 0) return@LaunchedEffect
        resolving = true; browser.error = null
        try {
            resolvedURL = withContext(Dispatchers.IO) {
                if (!notebooks && data.optString("kind") == "website") WorkspaceLocators.website(data.getString("url")).getString("url")
                else {
                    val broker = vm.brokers.firstOrNull { it.brokerID == data.optString("brokerID") } ?: error("This host is offline")
                    val info = if (notebooks) JSONObject(BrokerDocuments.read(broker, "/jupyter", timeoutSeconds = 210)) else null
                    val port = info?.getInt("port") ?: data.getInt("port")
                    Forwards.start(broker, port, data.optString("name"))?.let { error(it) }
                    val forward = Forwards.active.first { it.brokerHost == broker.host && it.remotePort == port }
                    val scheme = if (notebooks) "http" else data.optString("scheme", "http")
                    val path = if (notebooks) "/lab/tree/" + Uri.encode(data.optString("path").trimStart('/'), "/") else data.optString("path", "/")
                    "$scheme://127.0.0.1:${forward.localPort}$path" + (info?.optString("token")?.takeIf { it.isNotEmpty() }?.let { "?token=" + Uri.encode(it) } ?: "")
                }
            }
            if (browser.view != null && resolvedURL != null) browser.view?.loadUrl(resolvedURL!!)
        } catch (e: Exception) { browser.error = e.message }
        finally { resolving = false }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = close) { Text("Catalog") }
            Text(data.optString("name"), modifier = Modifier.weight(1f), maxLines = 1, color = LocalTheme.current.text, fontSize = 13.sp)
            TextButton(onClick = { browser.view?.goBack() }, enabled = browser.canGoBack) { Text("‹") }
            TextButton(onClick = { browser.view?.goForward() }, enabled = browser.canGoForward) { Text("›") }
            TextButton(onClick = { attempt++ }, enabled = !resolving) { Text("Reload") }
        }
        if (resolving || browser.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        browser.error?.let { Text(it, color = LocalTheme.current.waiting, modifier = Modifier.padding(12.dp)) }
        resolvedURL?.let { url ->
            AndroidView(modifier = Modifier.weight(1f).fillMaxWidth(), factory = { context ->
                browser.bind(context, url).also { web ->
                    (web.parent as? ViewGroup)?.removeView(web)
                    web.webChromeClient = object : WebChromeClient() {
                        override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                            fileCallback?.onReceiveValue(null); fileCallback = callback
                            picker.launch(params.acceptTypes.filter { it.isNotBlank() }.ifEmpty { listOf("*/*") }.toTypedArray()); return true
                        }
                    }
                }
            })
        }
    }
}
