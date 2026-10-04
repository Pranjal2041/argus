package dev.universaltmux.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

const val SCREEN_GIT = 13

@Composable
internal fun BrokerPicker(brokers: List<Broker>, selectedID: String?, select: (Broker) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { expanded = true }) { Text(brokers.firstOrNull { it.id == selectedID }?.name ?: "Choose host") }
        DropdownMenu(expanded, { expanded = false }) {
            brokers.forEach { broker -> DropdownMenuItem(text = { Text(broker.name) }, onClick = { expanded = false; select(broker) }) }
        }
    }
}

@Composable
fun GitScreen(vm: AppViewModel) {
    var brokerID by rememberSaveable { mutableStateOf(vm.selected?.first?.id ?: vm.brokers.firstOrNull()?.id) }
    val broker = vm.brokers.firstOrNull { it.id == brokerID }
    var directory by rememberSaveable { mutableStateOf(vm.selected?.let { (b, name) -> vm.sessions[b.id]?.firstOrNull { it.name == name }?.path } ?: "") }
    var currentDirectory by rememberSaveable { mutableStateOf(directory) }
    var tab by rememberSaveable { mutableStateOf("Changes") }
    var scope by rememberSaveable { mutableStateOf("head") }
    var commitPage by rememberSaveable { mutableStateOf(0) }
    var prState by rememberSaveable { mutableStateOf("open") }
    var filePath by rememberSaveable { mutableStateOf("") }
    var firstRef by rememberSaveable { mutableStateOf("HEAD") }
    var secondRef by rememberSaveable { mutableStateOf("HEAD~1") }
    var detail by remember { mutableStateOf<Pair<String, Map<String, String>>?>(null) }
    var selectedPR by rememberSaveable { mutableStateOf<Int?>(null) }
    val docs = vm.brokerDocuments
    val base = mapOf("dir" to currentDirectory)
    val endpoint = when (tab) { "History" -> "/git/log"; "Pull requests" -> "/git/prs"; else -> "/git/summary" }
    val query = when (tab) {
        "History" -> base + mapOf("n" to "50", "skip" to (commitPage * 50).toString(), "all" to "1")
        "Pull requests" -> base + ("state" to prState)
        else -> base
    }
    LaunchedEffect(broker?.id, currentDirectory, endpoint, query) {
        if (broker != null && currentDirectory.isNotBlank()) docs.refresh(broker, endpoint, query)
    }
    fun show(path: String, parameters: Map<String, String>) {
        if (broker != null) { detail = path to parameters; docs.refresh(broker, path, parameters) }
    }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Git & pull requests", fontSize = 22.sp, color = LocalTheme.current.text, modifier = Modifier.weight(1f))
                BrokerPicker(vm.brokers, brokerID) { brokerID = it.id; selectedPR = null; detail = null }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(directory, { directory = it }, label = { Text("Repository folder") }, singleLine = true, modifier = Modifier.weight(1f))
                TextButton(onClick = { currentDirectory = directory; if (broker != null) docs.refresh(broker, endpoint, query) }) { Text("Open") }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                listOf("Changes", "History", "Pull requests", "Compare & blame").forEach { label -> FilterChip(tab == label, { tab = label }, label = { Text(label) }) }
            }
        }
        if (broker == null || currentDirectory.isBlank()) item { Text("Choose a host and repository folder.", color = LocalTheme.current.dim) }
        else {
            val payload = docs.value(broker, endpoint, query)
            docs.issue(broker, endpoint, query)?.let { issue -> item { Text(issue, color = LocalTheme.current.waiting) } }
            if (docs.loading(broker, endpoint, query)) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            when (tab) {
                "Changes" -> {
                    val summary = runCatching { JSONObject(payload ?: "{}") }.getOrDefault(JSONObject())
                    item {
                        Text("${summary.optString("branch", "No reading yet")}  ↑${summary.optInt("ahead")} ↓${summary.optInt("behind")}", color = LocalTheme.current.text)
                        Text("${summary.optInt("stashes")} stashes · ${summary.optString("upstream")}", color = LocalTheme.current.dim, fontSize = 11.sp)
                        Row { listOf("head" to "All", "worktree" to "Unstaged", "staged" to "Staged").forEach { (key, label) ->
                            FilterChip(scope == key, { scope = key }, label = { Text(label) }, modifier = Modifier.padding(end = 6.dp))
                        } }
                    }
                    val files = summary.optJSONArray("files").objects().filter { row -> when (scope) { "staged" -> row.optString("staged") !in listOf("", "."); "worktree" -> row.optString("unstaged") !in listOf("", ".") || row.optBoolean("untracked"); else -> true } }
                    if (files.isEmpty()) item { Text(if (payload == null) "Waiting for repository…" else "No changes in this view", color = LocalTheme.current.dim) }
                    items(files, key = { it.optString("path") }) { file ->
                        Card(Modifier.fillMaxWidth().clickable {
                            filePath = file.optString("path")
                            if (file.optBoolean("untracked")) show("/fs/read", mapOf("path" to (summary.optString("root", currentDirectory).trimEnd('/') + "/" + filePath)))
                            else show("/git/diff", base + mapOf("scope" to scope, "path" to filePath))
                        }) {
                            Row(Modifier.padding(13.dp)) {
                                Text(if (file.optBoolean("untracked")) "??" else file.optString("staged") + file.optString("unstaged"), fontFamily = FontFamily.Monospace)
                                Spacer(Modifier.width(12.dp)); Text(file.optString("path"), fontSize = 13.sp)
                            }
                        }
                    }
                }
                "History" -> {
                    val commits = runCatching { JSONArray(payload ?: "[]").objects() }.getOrDefault(emptyList())
                    items(commits, key = { it.optString("hash") }) { commit ->
                        Card(Modifier.fillMaxWidth().clickable { show("/git/diff", base + mapOf("scope" to "commit", "hash" to commit.optString("hash"))) }) {
                            Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                Text(commit.optString("subject"), fontSize = 14.sp)
                                Text("${commit.optString("hash").take(8)} · ${commit.optString("author")} · ${workspaceDate(commit.optLong("at") * 1000)}", fontSize = 10.sp)
                            }
                        }
                    }
                    item { Row { TextButton(onClick = { commitPage-- }, enabled = commitPage > 0) { Text("Previous") }; TextButton(onClick = { commitPage++ }, enabled = commits.size == 50) { Text("Next 50") } } }
                }
                "Pull requests" -> {
                    item { Row(Modifier.horizontalScroll(rememberScrollState())) { listOf("open", "closed", "merged", "all").forEach { state ->
                        FilterChip(prState == state, { prState = state }, label = { Text(state) }, modifier = Modifier.padding(end = 6.dp))
                    } } }
                    val prs = runCatching { JSONArray(payload ?: "[]").objects() }.getOrDefault(emptyList())
                    items(prs, key = { it.optInt("number") }) { pr ->
                        Card(Modifier.fillMaxWidth().clickable { selectedPR = pr.optInt("number") }) {
                            Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                Text("#${pr.optInt("number")}  ${pr.optString("title")}", fontSize = 15.sp)
                                Text("${pr.optString("headRefName")} → ${pr.optString("baseRefName")} · ${pr.optString("reviewDecision")}", fontSize = 11.sp)
                                Text("+${pr.optInt("additions")} −${pr.optInt("deletions")} · ${pr.optInt("changedFiles")} files", fontSize = 11.sp)
                            }
                        }
                    }
                    if (payload != null && prs.isEmpty()) item { Text("No pull requests in this view", color = LocalTheme.current.dim) }
                }
                else -> item {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedTextField(secondRef, { secondRef = it }, label = { Text("Base revision") }, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(firstRef, { firstRef = it }, label = { Text("Target revision") }, modifier = Modifier.fillMaxWidth())
                        OutlinedTextField(filePath, { filePath = it }, label = { Text("File path (optional for compare)") }, modifier = Modifier.fillMaxWidth())
                        Button(onClick = { show("/git/diff", base + mapOf("scope" to "range", "hash" to firstRef, "hash2" to secondRef, "path" to filePath)) }) { Text("Compare revisions") }
                        Button(onClick = { show("/git/blame", base + mapOf("ref" to firstRef, "path" to filePath)) }, enabled = filePath.isNotBlank()) { Text("Blame file") }
                        Button(onClick = { show("/git/show", base + mapOf("ref" to firstRef, "path" to filePath)) }, enabled = filePath.isNotBlank()) { Text("File at revision") }
                    }
                }
            }
        }
    }
    if (broker != null) {
        detail?.let { (path, params) -> TextDocumentDialog(path.removePrefix("/git/").replaceFirstChar(Char::uppercase), docs.value(broker, path, params), docs.issue(broker, path, params)) { detail = null } }
        selectedPR?.let { PRDetail(vm, broker, currentDirectory, it, { selectedPR = null }) { path, params -> show(path, params) } }
    }
}

@Composable
internal fun TextDocumentDialog(title: String, text: String?, issue: String? = null, close: () -> Unit) {
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = LocalTheme.current.bg) {
            Column(Modifier.padding(14.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) { Text(title, color = LocalTheme.current.text, modifier = Modifier.weight(1f)); TextButton(onClick = close) { Text("Close") } }
                issue?.let { Text(it, color = LocalTheme.current.waiting) }
                if (text == null && issue == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                SelectionContainer {
                    LazyColumn(Modifier.fillMaxSize().horizontalScroll(rememberScrollState())) {
                        items((text ?: "").lines()) { line ->
                            Text(line.ifEmpty { " " }, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                                color = when { line.startsWith("+") -> LocalTheme.current.live; line.startsWith("-") -> LocalTheme.current.bad; line.startsWith("@@") -> LocalTheme.current.accent; else -> LocalTheme.current.text })
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PRDetail(vm: AppViewModel, broker: Broker, directory: String, number: Int, close: () -> Unit, show: (String, Map<String, String>) -> Unit) {
    val query = mapOf("dir" to directory, "num" to number.toString())
    val docs = vm.brokerDocuments
    LaunchedEffect(broker.id, directory, number) { docs.refresh(broker, "/git/pr", query) }
    val pr = runCatching { JSONObject(docs.value(broker, "/git/pr", query) ?: "{}") }.getOrDefault(JSONObject())
    var body by rememberSaveable(broker.id, directory, number) { mutableStateOf("") }
    var action by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val coroutine = rememberCoroutineScope()
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = LocalTheme.current.bg) {
            LazyColumn(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item { Row { Text("PR #$number", color = LocalTheme.current.text, fontSize = 22.sp, modifier = Modifier.weight(1f)); TextButton(onClick = close) { Text("Close") } } }
                item {
                    Text(pr.optString("title"), color = LocalTheme.current.text, fontSize = 20.sp)
                    Text("${pr.optString("state")} · ${pr.optString("mergeable")} · ${pr.optString("reviewDecision")}", color = LocalTheme.current.dim, fontSize = 12.sp)
                    docs.issue(broker, "/git/pr", query)?.let { Text(it, color = LocalTheme.current.waiting) }
                    SelectionContainer { Text(pr.optString("body"), color = LocalTheme.current.text, fontSize = 13.sp) }
                    TextButton(onClick = { close(); show("/git/pr/diff", query) }) { Text("Review diff") }
                }
                items(pr.optJSONArray("statusCheckRollup").objects()) { check -> Text("${check.optString("name", check.optString("context"))} · ${check.optString("conclusion", check.optString("state"))}", color = LocalTheme.current.dim, fontSize = 12.sp) }
                items(pr.optJSONArray("files").objects()) { file -> Text("${file.optString("path")}  +${file.optInt("additions")} −${file.optInt("deletions")}", color = LocalTheme.current.text, fontSize = 12.sp) }
                items(pr.optJSONArray("reviews").objects() + pr.optJSONArray("comments").objects()) { comment ->
                    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) { Text("${comment.optJSONObject("author")?.optString("login").orEmpty()} · ${comment.optString("state")}"); Text(comment.optString("body"), fontSize = 12.sp) } }
                }
                item {
                    OutlinedTextField(body, { body = it }, label = { Text("Review or comment") }, modifier = Modifier.fillMaxWidth(), minLines = 3)
                    error?.let { Text(it, color = LocalTheme.current.waiting) }
                    Row(Modifier.horizontalScroll(rememberScrollState())) {
                        listOf("Comment", "Approve", "Request changes", "Squash merge").forEach { kind ->
                            TextButton(onClick = { action = kind }, enabled = !busy && (kind !in listOf("Comment", "Request changes") || body.isNotBlank())) { Text(kind) }
                        }
                    }
                }
            }
        }
    }
    action?.let { kind -> AlertDialog(onDismissRequest = { if (!busy) action = null }, title = { Text("$kind PR #$number?") }, text = { Text(body.ifBlank { pr.optString("title") }) },
        confirmButton = { TextButton(enabled = !busy, onClick = {
            busy = true; error = null
            coroutine.launch {
                try {
                    val path = when (kind) { "Comment" -> "/git/pr/comment"; "Squash merge" -> "/git/pr/merge"; else -> "/git/pr/review" }
                    val params = query + mapOf("body" to body, "method" to "squash", "event" to if (kind == "Approve") "APPROVE" else "REQUEST_CHANGES")
                    withContext(Dispatchers.IO) { BrokerDocuments.write(broker, path, params) }
                    action = null; body = ""; docs.refresh(broker, "/git/pr", query)
                } catch (e: Exception) { error = e.message; action = null }
                finally { busy = false }
            }
        }) { Text(if (busy) "Submitting…" else kind) } }, dismissButton = { TextButton(enabled = !busy, onClick = { action = null }) { Text("Cancel") } }) }
}
