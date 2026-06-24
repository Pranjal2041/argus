package dev.universaltmux.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val wfInk: Color @Composable get() = LocalTheme.current.bg
private val wfPanel: Color @Composable get() = LocalTheme.current.panelAlt
private val wfText: Color @Composable get() = LocalTheme.current.text
private val wfDim: Color @Composable get() = LocalTheme.current.dim
private val wfFaint: Color @Composable get() = LocalTheme.current.faint
private val wfAccent: Color @Composable get() = LocalTheme.current.accent

private fun swatchColor(hex: String, fallback: Color): Color =
    if (hex.isEmpty()) fallback else runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(fallback)

@Composable
fun WorkflowsScreen(vm: AppViewModel, onRan: () -> Unit) {
    var editing by remember { mutableStateOf<Workflow?>(null) }
    var creating by remember { mutableStateOf(false) }
    var picker by remember { mutableStateOf<Pair<Workflow, List<Broker>>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun run(wf: Workflow) {
        val ms = vm.brokersMatching(wf.machine)
        when {
            ms.isEmpty() -> error = "No reachable machine matches \"${wf.machine}\"."
            ms.size == 1 -> { vm.runWorkflowOn(wf, ms[0]); onRan() }
            else -> picker = wf to ms
        }
    }

    Column(Modifier.fillMaxSize().background(wfInk)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Workflows", color = wfText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { creating = true }) { Icon(Icons.Filled.Add, "New workflow", tint = wfAccent) }
        }
        Divider(color = wfFaint.copy(alpha = 0.2f))
        if (vm.workflows.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No workflows yet. Tap + to add one.", color = wfDim, fontSize = 15.sp)
            }
        } else {
            val groups = vm.workflows.groupBy { it.machine }.toSortedMap()
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                groups.forEach { (machine, list) ->
                    item("h:$machine") {
                        Text(machine.ifEmpty { "—" }, color = wfFaint, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(top = 6.dp, start = 2.dp))
                    }
                    items(list, key = { it.id }) { wf -> WorkflowCard(wf, onRun = { run(wf) }, onEdit = { editing = wf }) }
                }
            }
        }
    }

    if (creating) WorkflowForm(vm, null) { creating = false }
    editing?.let { wf -> WorkflowForm(vm, wf) { editing = null } }
    picker?.let { (wf, ms) ->
        AlertDialog(onDismissRequest = { picker = null },
            title = { Text("Run on which machine?") },
            text = { Column { ms.forEach { b -> TextButton(onClick = { vm.runWorkflowOn(wf, b); picker = null; onRan() }) { Text(b.name) } } } },
            confirmButton = {}, dismissButton = { TextButton(onClick = { picker = null }) { Text("Cancel") } })
    }
    error?.let { msg ->
        AlertDialog(onDismissRequest = { error = null }, title = { Text("Workflow") }, text = { Text(msg) },
            confirmButton = { TextButton(onClick = { error = null }) { Text("OK") } })
    }
}

@Composable
private fun WorkflowCard(wf: Workflow, onRun: () -> Unit, onEdit: () -> Unit) {
    val accent = swatchColor(wf.colorHex, wfAccent)
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(11.dp)).background(wfPanel).clickable { onRun() }.padding(14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(Modifier.size(9.dp).clip(CircleShape).background(accent))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(wf.name.ifEmpty { "(unnamed)" }, color = wfText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            if (wf.folder.isNotEmpty()) Text(wf.folder, color = wfDim, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 1)
            if (wf.notes.isNotEmpty()) Text(wf.notes, color = wfFaint, fontSize = 11.sp, maxLines = 1)
        }
        IconButton(onClick = onEdit) { Icon(Icons.Filled.Edit, "Edit", tint = wfFaint) }
        Icon(Icons.Filled.PlayArrow, "Run", tint = accent)
    }
}

@Composable
private fun WorkflowForm(vm: AppViewModel, existing: Workflow?, onClose: () -> Unit) {
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var machine by remember { mutableStateOf(existing?.machine ?: "") }
    var folder by remember { mutableStateOf(existing?.folder ?: "") }
    var commands by remember { mutableStateOf(existing?.commands ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var color by remember { mutableStateOf(existing?.colorHex ?: "") }
    val swatches = listOf("", "#E5484D", "#F5A623", "#30A46C", "#3B82F6", "#8B5CF6", "#EC4899")
    val suggestions = listOf("this mac") + vm.brokers.map { it.name }

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (existing == null) "New Workflow" else "Edit Workflow") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(machine, { machine = it }, singleLine = true, label = { Text("Machine (babel-*  ·  this mac)") }, modifier = Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 4.dp)) {
                    suggestions.distinct().forEach { s ->
                        Text(s, color = wfAccent, fontSize = 12.sp,
                            modifier = Modifier.padding(end = 8.dp).clip(RoundedCornerShape(6.dp)).background(wfPanel).clickable { machine = s }.padding(horizontal = 8.dp, vertical = 4.dp))
                    }
                }
                OutlinedTextField(folder, { folder = it }, singleLine = true, label = { Text("Folder (~/scratch)") }, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(commands, { commands = it }, label = { Text("Commands (one per line)") }, modifier = Modifier.fillMaxWidth().height(120.dp))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(notes, { notes = it }, singleLine = true, label = { Text("Notes (optional)") }, modifier = Modifier.fillMaxWidth())
                Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    swatches.forEach { hex ->
                        val c = swatchColor(hex, Color.Gray.copy(alpha = 0.4f))
                        Box(Modifier.padding(end = 9.dp).size(20.dp).clip(CircleShape).background(c)
                            .clickable { color = hex }
                            .then(if (color == hex) Modifier.padding(0.dp) else Modifier)) {
                            if (color == hex) Text("✓", color = wfText, fontSize = 12.sp, modifier = Modifier.align(Alignment.Center))
                        }
                    }
                }
                if (existing != null) {
                    TextButton(onClick = { vm.deleteWorkflow(existing); onClose() }) { Text("Delete", color = LocalTheme.current.bad) }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank() && machine.isNotBlank(),
                onClick = {
                    val w = (existing ?: Workflow()).copy(name = name, machine = machine, folder = folder, commands = commands, notes = notes, colorHex = color)
                    vm.upsertWorkflow(w); onClose()
                }
            ) { Text(if (existing == null) "Add" else "Save") }
        },
        dismissButton = { TextButton(onClick = onClose) { Text("Cancel") } }
    )
}
