package dev.universaltmux.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val tInk: Color @Composable get() = LocalTheme.current.bg
private val tPanel: Color @Composable get() = LocalTheme.current.panelAlt
private val tText: Color @Composable get() = LocalTheme.current.text
private val tDim: Color @Composable get() = LocalTheme.current.dim
private val tFaint: Color @Composable get() = LocalTheme.current.faint
private val tAccent: Color @Composable get() = LocalTheme.current.accent
private val tWorking: Color @Composable get() = LocalTheme.current.working

@Composable
fun TodoMapsScreen(vm: AppViewModel, onOpenSession: () -> Unit) {
    var showFinished by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }

    val misc = vm.todoBoards.filter { it.isMisc }
    var sessionBoards = vm.todoBoards.filter { !it.isMisc }
    if (!showFinished) sessionBoards = sessionBoards.filter { it.items.isEmpty() || it.pending > 0 }
    sessionBoards = sessionBoards.sortedWith(
        compareByDescending<TodoBoard> { vm.isSessionLive(it) }.thenBy { it.session.lowercase() }
    )
    val boards = misc + sessionBoards

    Column(Modifier.fillMaxSize().background(tInk)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Todo Maps", color = tText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            Text("Finished", color = tDim, fontSize = 12.sp)
            Switch(checked = showFinished, onCheckedChange = { showFinished = it })
            IconButton(onClick = { adding = true }) { Icon(Icons.Filled.Add, "New panel", tint = tAccent) }
        }
        Divider(color = tFaint.copy(alpha = 0.2f))
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(boards, key = { it.id }) { board -> TodoBoardCard(vm, board, onOpenSession) }
        }
    }

    if (adding) AddBoardDialog(vm) { adding = false }
}

@Composable
private fun TodoBoardCard(vm: AppViewModel, board: TodoBoard, onOpenSession: () -> Unit) {
    var newText by remember { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    val live = vm.isSessionLive(board)
    val items = board.items.sortedWith(Comparator { a, b ->
        if (a.done != b.done) return@Comparator if (a.done) 1 else -1
        if (a.done) (b.completedAt ?: b.createdAt).compareTo(a.completedAt ?: a.createdAt)
        else a.createdAt.compareTo(b.createdAt)
    })

    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(13.dp)).background(tPanel).padding(15.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!board.isMisc) {
                Box(Modifier.size(9.dp).clip(CircleShape).background(if (live) tWorking else tFaint.copy(alpha = 0.5f)))
                Spacer(Modifier.width(9.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(if (board.isMisc) "Misc" else board.session, color = tText, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                if (!board.isMisc) Text(board.machine, color = tFaint, fontSize = 12.sp, maxLines = 1)
            }
            if (board.pending > 0) {
                Text("${board.pending}", color = tDim, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(tInk).padding(horizontal = 7.dp, vertical = 2.dp))
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "Menu", tint = tFaint) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (live) DropdownMenuItem(text = { Text("Open session") }, onClick = {
                        menu = false; vm.liveBrokerFor(board)?.let { vm.selected = it to board.session; onOpenSession() }
                    })
                    if (board.items.any { it.done }) DropdownMenuItem(text = { Text("Clear completed") }, onClick = {
                        menu = false; board.items.filter { it.done }.forEach { vm.deleteTodo(board.id, it.id) }
                    })
                    if (!board.isMisc) DropdownMenuItem(text = { Text("Delete panel") }, onClick = { menu = false; vm.deleteBoard(board.id) })
                }
            }
        }
        Divider(color = tFaint.copy(alpha = 0.18f), modifier = Modifier.padding(vertical = 9.dp))
        if (items.isEmpty()) {
            Text("No tasks yet", color = tFaint, fontSize = 13.sp, modifier = Modifier.padding(bottom = 6.dp))
        }
        items.forEach { item ->
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 2.dp)) {
                IconButton(onClick = { vm.toggleTodo(board.id, item.id) }, modifier = Modifier.size(34.dp)) {
                    Icon(if (item.done) Icons.Filled.CheckCircle else Icons.Outlined.Circle, "Toggle",
                        tint = if (item.done) tWorking else tFaint)
                }
                Text(item.text, color = if (item.done) tFaint else tText, fontSize = 15.sp,
                    textDecoration = if (item.done) TextDecoration.LineThrough else null, modifier = Modifier.weight(1f).padding(start = 4.dp))
                IconButton(onClick = { vm.deleteTodo(board.id, item.id) }, modifier = Modifier.size(30.dp)) {
                    Icon(Icons.Filled.Close, "Delete", tint = tFaint, modifier = Modifier.size(15.dp))
                }
            }
        }
        OutlinedTextField(
            value = newText, onValueChange = { newText = it },
            placeholder = { Text("Add a task", fontSize = 15.sp) }, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { if (newText.isNotBlank()) { vm.addTodo(board.id, newText); newText = "" } })
        )
    }
}

@Composable
private fun AddBoardDialog(vm: AppViewModel, onClose: () -> Unit) {
    var machine by remember { mutableStateOf("") }
    var session by remember { mutableStateOf("") }
    val live = vm.brokers.flatMap { b -> (vm.sessions[b.id] ?: emptyList()).filter { !it.agent }.map { b.name to it.name } }

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text("New Todo Panel") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (live.isNotEmpty()) {
                    Text("Pick a running session", color = tDim, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    live.forEach { (m, s) ->
                        Text("$s   ·   $m", color = tText, fontSize = 14.sp,
                            modifier = Modifier.fillMaxWidth().clickable { machine = m; session = s }.padding(vertical = 7.dp))
                    }
                    Divider(color = tFaint.copy(alpha = 0.2f), modifier = Modifier.padding(vertical = 6.dp))
                    Text("or type a future one", color = tFaint, fontSize = 11.sp)
                }
                OutlinedTextField(machine, { machine = it }, singleLine = true, label = { Text("Machine") }, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(session, { session = it }, singleLine = true, label = { Text("Session name") }, modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = {
            TextButton(enabled = machine.isNotBlank() && session.isNotBlank(),
                onClick = { vm.ensureBoard(machine, session); onClose() }) { Text("Add") }
        },
        dismissButton = { TextButton(onClick = onClose) { Text("Cancel") } }
    )
}
