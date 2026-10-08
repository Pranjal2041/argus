package dev.universaltmux.android

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Never persisted or retried: credentials and authorization codes only live in
 * this request and the collector's private credential store, not replica state. */
internal object UsageAccountService {
    suspend fun call(broker: Broker, body: JSONObject): JSONObject = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(broker.httpBase + "/workspace/service/usage")
            .header("Cache-Control", "no-store").post(body.toString().toRequestBody("application/json".toMediaType())).build()
        Net.client.newBuilder().retryOnConnectionFailure(false).readTimeout(50, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Collector request was not acknowledged (HTTP ${response.code}). Reload connections before retrying.")
            val value = JSONObject(response.body?.string() ?: throw IOException("Empty collector response"))
            if (value.has("error")) throw IOException(value.getString("error"))
            value
        }
    }
}

@Composable
internal fun UsageConnections(vm: AppViewModel, close: () -> Unit) {
    val workspaceID = vm.workspace.workspaceID
    val scope = rememberCoroutineScope()
    var state by remember(workspaceID) { mutableStateOf<JSONObject?>(null) }
    var issue by remember(workspaceID) { mutableStateOf<String?>(null) }
    var busy by remember(workspaceID) { mutableStateOf(false) }
    var draft by remember(workspaceID) { mutableStateOf<JSONObject?>(null) }
    var removing by remember { mutableStateOf<JSONObject?>(null) }
    var code by remember { mutableStateOf("") }
    var loginURL by remember { mutableStateOf<String?>(null) }
    val browser = remember(workspaceID) { WorkspaceBrowserSession("usage-sign-in") }
    DisposableEffect(browser) { onDispose { browser.close() } }
    suspend fun request(value: JSONObject): Boolean {
        if (busy) return false
        busy = true
        return try {
            val host = vm.workspaceHost() ?: throw IOException("The workspace collector is offline.")
            val result = UsageAccountService.call(host, value)
            check(workspaceID == vm.workspace.workspaceID) { "The selected workspace changed." }
            state = result; issue = null; true
        } catch (error: Exception) { issue = error.message; false }
        finally { busy = false }
    }
    fun action(name: String, sourceID: String? = null) {
        scope.launch { request(JSONObject().put("action", name).put("sourceID", sourceID)) }
    }
    LaunchedEffect(workspaceID) {
        while (true) { request(JSONObject().put("action", "state")); delay(5_000) }
    }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Connections", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
                    TextButton(onClick = close) { Text("Done") }
                }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                issue?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (loginURL != null) {
                    TextButton(onClick = { loginURL = null; browser.close() }) { Text("Back to sign-in code") }
                    browser.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    AndroidView(factory = { context -> browser.bind(context, loginURL!!) }, modifier = Modifier.weight(1f).fillMaxWidth())
                } else Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val integrations = state?.optJSONArray("integrations").objects()
                    val current = draft
                    if (current != null) {
                        val definition = integrations.firstOrNull { it.optString("id") == current.optString("integration") }
                        if (!current.has("sourceID")) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            integrations.forEach { integration -> FilterChip(selected = integration == definition,
                                onClick = { draft = JSONObject(integration.optJSONObject("defaults")?.toString() ?: "{}").put("codexLoginMethod", "deviceCode") },
                                label = { Text(integration.optString("name")) }) }
                        }
                        Text(definition?.optString("name") ?: "Connection", style = MaterialTheme.typography.titleLarge)
                        definition?.optString("help")?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                        definition?.optJSONArray("fields").objects().forEach { field ->
                            val key = field.getString("id")
                            OutlinedTextField(current.optString(key), { draft = JSONObject(current.toString()).put(key, it) },
                                label = { Text(field.getString("title")) }, modifier = Modifier.fillMaxWidth(), enabled = !busy)
                        }
                        definition?.optJSONArray("credentialFields").objects().forEach { field ->
                            val key = field.getString("id")
                            OutlinedTextField(current.optJSONObject("credentials")?.optString(key).orEmpty(), { value ->
                                val credentials = JSONObject(current.optJSONObject("credentials")?.toString() ?: "{}").put(key, value)
                                draft = JSONObject(current.toString()).put("credentials", credentials)
                            }, label = { Text(field.getString("title") + if (current.optBoolean("hasSavedCredentials")) " (blank keeps saved key)" else "") },
                                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(), enabled = !busy)
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Switch(current.optBoolean("enabled", true), { draft = JSONObject(current.toString()).put("enabled", it) }, enabled = !busy)
                            Text("Enabled", Modifier.padding(start = 10.dp))
                        }
                        Row {
                            Button(onClick = { scope.launch {
                                val payload = JSONObject(current.toString())
                                // Clear secret input immediately after submission, even on error.
                                draft = JSONObject(current.toString()).put("credentials", JSONObject())
                                if (request(JSONObject().put("action", "save").put("draft", payload))) draft = null
                            } }, enabled = !busy) { Text("Save connection") }
                            TextButton(onClick = { draft = null }, enabled = !busy) { Text("Cancel") }
                        }
                    } else {
                        Text("Managed by the workspace collector", style = MaterialTheme.typography.bodySmall)
                        Button(onClick = { integrations.firstOrNull()?.let { draft = JSONObject(it.getJSONObject("defaults").toString()).put("codexLoginMethod", "deviceCode") } }, enabled = !busy && integrations.isNotEmpty()) { Text("Add connection") }
                        state?.optJSONArray("connections").objects().forEach { connection ->
                            val definition = integrations.firstOrNull { it.optString("id") == connection.optString("integration") }
                            Card(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(connection.optString("label"), style = MaterialTheme.typography.titleMedium)
                                    Text("${definition?.optString("name") ?: connection.optString("integration")} · ${if (connection.optBoolean("enabled")) "Enabled" else "Disabled"}")
                                    Row {
                                        TextButton(onClick = { draft = JSONObject(connection.toString()) }, enabled = !busy) { Text("Edit") }
                                        if (definition?.optBoolean("signIn") == true) TextButton(onClick = { action("connect", connection.getString("id")) }, enabled = !busy && connection.optBoolean("enabled") && !state!!.has("loginSourceID")) { Text("Sign in") }
                                        TextButton(onClick = { removing = connection }, enabled = !busy) { Text("Remove") }
                                    }
                                }
                            }
                        }
                    }
                    state?.optString("message")?.takeIf(String::isNotEmpty)?.let { Text(it) }
                    val link = state?.optString("url").orEmpty()
                    if (link.isNotEmpty()) {
                        state?.optString("userCode")?.takeIf(String::isNotEmpty)?.let { Text(it, style = MaterialTheme.typography.headlineMedium) }
                        TextButton(onClick = { browser.close(); loginURL = link }) { Text("Open sign-in in UT Browser") }
                        if (state?.optString("userCode").isNullOrEmpty()) {
                            OutlinedTextField(code, { code = it }, label = { Text("Authorization code") }, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                            Button(onClick = { val submitted = code; code = ""; scope.launch { request(JSONObject().put("action", "finish").put("code", submitted)) } }, enabled = !busy && code.isNotBlank()) { Text("Finish sign-in") }
                        }
                    }
                    if (state?.has("loginSourceID") == true) TextButton(onClick = { code = ""; action("cancel") }, enabled = !busy) { Text("Cancel sign-in") }
                }
            }
        }
    }
    removing?.let { connection -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove ${connection.optString("label")}?") },
        text = { Text("The collector will stop checking this connection. Original CLI profiles remain unchanged.") },
        confirmButton = { TextButton(onClick = { action("remove", connection.getString("id")); removing = null }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
}
