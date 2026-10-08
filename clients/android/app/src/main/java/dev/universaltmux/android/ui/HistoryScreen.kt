package dev.universaltmux.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONObject

const val SCREEN_HISTORY = 12

@Composable
fun HistoryScreen(vm: AppViewModel, open: (Broker, String) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var includeAgents by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Pair<Broker, JSONObject>?>(null) }
    val docs = vm.brokerDocuments
    LaunchedEffect(vm.brokers.map { it.brokerID.ifEmpty { it.id } }) { vm.brokers.forEach { docs.refresh(it, "/history") } }
    val rows = vm.brokers.flatMap { broker ->
        runCatching { JSONObject(docs.value(broker, "/history") ?: "{}").optJSONArray("sessions").objects() }.getOrDefault(emptyList()).map { broker to it }
    }.filter { (b, row) -> (includeAgents || !row.optBoolean("agent")) &&
        (b.name + " " + row.optString("name") + " " + row.optJSONArray("folders").objects().joinToString { it.optString("path") }).contains(query, true) }
        .sortedByDescending { it.second.optLong("last") }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
        item {
            Row { Text("Session history", fontSize = 24.sp, color = LocalTheme.current.text, modifier = Modifier.weight(1f))
                TextButton(onClick = { vm.brokers.forEach { docs.refresh(it, "/history") } }) { Text("Refresh") } }
            Text("Sessions and folders, including closed panels", color = LocalTheme.current.dim, fontSize = 12.sp)
        }
        item { OutlinedTextField(query, { query = it }, label = { Text("Find session, host, or folder") }, modifier = Modifier.fillMaxWidth()) }
        item { FilterChip(includeAgents, { includeAgents = !includeAgents }, label = { Text("Include background agents") }) }
        vm.brokers.forEach { broker ->
            docs.issue(broker, "/history")?.let { issue -> item { Text("${broker.name}: $issue", color = LocalTheme.current.waiting, fontSize = 12.sp) } }
        }
        if (rows.isEmpty()) item { Text("No matching sessions", color = LocalTheme.current.dim) }
        items(rows, key = { (b, row) -> "${b.id}/${row.optString("name")}" }) { (broker, row) ->
            Card(Modifier.fillMaxWidth().clickable { selected = broker to row }) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(row.optString("name"), fontSize = 17.sp)
                    Text("${broker.name} · ${if (row.optBoolean("alive")) "live" else "closed"}", fontSize = 12.sp)
                    Text(workspaceDate(row.optLong("last") * 1000), fontSize = 11.sp)
                    row.optJSONArray("folders").objects().lastOrNull()?.let { Text(it.optString("path"), fontSize = 12.sp) }
                }
            }
        }
    }
    selected?.let { (broker, row) ->
        AlertDialog(onDismissRequest = { selected = null }, title = { Text(row.optString("name")) }, text = {
            LazyColumn(Modifier.heightIn(max = 420.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(row.optJSONArray("folders").objects().reversed()) { folder ->
                    Column { Text(folder.optString("path")); Text("${workspaceDate(folder.optLong("first") * 1000)} — ${workspaceDate(folder.optLong("last") * 1000)}", fontSize = 11.sp) }
                }
            }
        }, confirmButton = { if (row.optBoolean("alive")) TextButton(onClick = { selected = null; open(broker, row.optString("name")) }) { Text("Open terminal") } },
            dismissButton = { TextButton(onClick = { selected = null }) { Text("Close") } })
    }
}
