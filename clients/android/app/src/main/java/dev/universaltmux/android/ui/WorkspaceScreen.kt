package dev.universaltmux.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun WorkspaceScreen(vm: AppViewModel) {
    val replica = vm.workspace
    val theme = LocalTheme.current
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Shared workspace", fontSize = 25.sp, color = theme.text)
        Text("One workspace across your devices", fontSize = 13.sp, color = theme.dim)
        val hosts = vm.brokers.filter { it.workspaceEnabled && it.workspaceID.isNotEmpty() }.distinctBy { it.workspaceID }
        hosts.forEach { broker ->
            OutlinedButton(onClick = { vm.selectWorkspace(broker) }, enabled = !replica.syncing, modifier = Modifier.fillMaxWidth()) {
                Text((if (broker.workspaceID == replica.workspaceID) "✓  " else "") + broker.name)
            }
        }
        (vm.workspaceSelectionIssue ?: replica.issue)?.let { Text(it, color = theme.waiting) }
        Text(if (replica.syncing) "Synchronizing…" else "${replica.pending.size} pending changes", color = theme.dim)
        Button(onClick = { vm.refreshWorkspace(force = true); vm.syncUserData() }) { Text("Sync now") }
        listOf("notes", "todos", "workflows", "planner").forEach { key -> WorkspaceSyncBanner(vm, key) }
        replica.pending.forEach { operation ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(operation.getString("collection"), fontSize = 13.sp)
                    Text(if (operation.has("conflict")) "Concurrent edits need review" else "Waiting for acknowledgment", fontSize = 12.sp)
                    if (operation.has("conflict")) {
                        var reviewing by remember { mutableStateOf(false) }
                        TextButton(onClick = { reviewing = true }) { Text("Review both copies") }
                        if (reviewing) AlertDialog(onDismissRequest = { reviewing = false }, title = { Text("Choose a version") }, text = {
                            Column(Modifier.heightIn(max = 380.dp).verticalScroll(rememberScrollState())) {
                                Text("This device"); Text(operation.optJSONObject("data")?.toString(2) ?: "Deleted")
                                Spacer(Modifier.height(12.dp)); Text("Shared version")
                                Text(replica.record(operation.getString("collection"), operation.getString("id"))?.data?.toString(2) ?: "Deleted")
                            }
                        }, confirmButton = { TextButton(onClick = { replica.resolve(operation.getString("mutationID"), true); reviewing = false; vm.refreshWorkspace(true) }) { Text("Keep this edit") } },
                            dismissButton = { TextButton(onClick = { replica.resolve(operation.getString("mutationID"), false); reviewing = false }) { Text("Use shared version") } })
                    }
                }
            }
        }
    }
}
