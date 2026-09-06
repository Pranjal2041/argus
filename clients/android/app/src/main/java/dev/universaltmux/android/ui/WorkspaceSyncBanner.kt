package dev.universaltmux.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable
fun WorkspaceSyncBanner(vm: AppViewModel, key: String) {
    val issue = vm.workspaceSyncIssues[key] ?: return
    var reviewing by remember { mutableStateOf<String?>(null) }
    var document by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    Row(Modifier.fillMaxWidth().padding(12.dp)) {
        Text(issue, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.error)
        if (vm.workspaceConflict(key) != null) TextButton(onClick = {
            reviewing = vm.workspaceConflict(key)
            document = JSONObject(reviewing!!).getJSONArray("local").toString(2); error = null
        }) { Text("Review") }
    }
    reviewing?.let { saved ->
        val conflict = JSONObject(saved)
        AlertDialog(onDismissRequest = { reviewing = null }, title = { Text("Review $key edits") }, text = {
            Column(Modifier.heightIn(max = 500.dp).verticalScroll(rememberScrollState())) {
                Text("Both copies are preserved. Choose a starting copy, edit the JSON, then apply. Newer remote edits are checked again.")
                TextButton(onClick = { document = conflict.getJSONArray("local").toString(2) }) { Text("Start with phone copy") }
                TextButton(onClick = { document = conflict.getJSONArray("remote").toString(2) }) { Text("Start with sync-host copy") }
                OutlinedTextField(value = document, onValueChange = { document = it }, modifier = Modifier.fillMaxWidth(), label = { Text("Merged records") })
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        }, confirmButton = {
            TextButton(onClick = {
                try { vm.resolveWorkspaceConflict(key, saved, document); reviewing = null }
                catch (e: Exception) { error = e.message }
            }) { Text("Apply reviewed merge") }
        }, dismissButton = { TextButton(onClick = { reviewing = null }) { Text("Cancel") } })
    }
}
