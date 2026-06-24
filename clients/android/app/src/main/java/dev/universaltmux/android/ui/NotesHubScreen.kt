package dev.universaltmux.android

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

private val nInk: Color @Composable get() = LocalTheme.current.bg
private val nPanel: Color @Composable get() = LocalTheme.current.panelAlt
private val nText: Color @Composable get() = LocalTheme.current.text
private val nDim: Color @Composable get() = LocalTheme.current.dim
private val nFaint: Color @Composable get() = LocalTheme.current.faint
private val nAccent: Color @Composable get() = LocalTheme.current.accent
private val nWorking: Color @Composable get() = LocalTheme.current.working

/** The note's time bucket: 0 Today, 1 Yesterday, 2 Earlier this week, 3 This month, 4 Earlier. */
private fun bucketOf(iso: String): Int {
    val created = try { Instant.parse(iso).atZone(ZoneId.systemDefault()).toLocalDate() } catch (e: Exception) { return 4 }
    val today = LocalDate.now()
    val weekStart = today.minusDays((today.dayOfWeek.value - 1).toLong())
    return when {
        created == today -> 0
        created == today.minusDays(1) -> 1
        created >= weekStart -> 2
        created.year == today.year && created.monthValue == today.monthValue -> 3
        else -> 4
    }
}

private fun timeLabel(iso: String): String = try {
    Instant.parse(iso).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("MMM d · h:mm a"))
} catch (e: Exception) { "" }

@Composable
fun NotesHubScreen(vm: AppViewModel) {
    val labels = listOf("Today", "Yesterday", "Earlier this week", "This month", "Earlier")
    val byBucket = vm.notes.groupBy { bucketOf(it.createdAt) }
    val groups = (0..4).mapNotNull { b ->
        byBucket[b]?.takeIf { it.isNotEmpty() }?.let { b to it.sortedByDescending { n -> n.createdAt } }
    }

    Column(Modifier.fillMaxSize().background(nInk)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Notes", color = nText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { vm.addNote() }) { Icon(Icons.Filled.Add, "New note", tint = nAccent) }
        }
        Divider(color = nFaint.copy(alpha = 0.2f))
        if (vm.notes.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No notes yet. Tap + to write one.", color = nDim, fontSize = 15.sp)
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                groups.forEach { (b, ns) ->
                    item("h:$b") {
                        Text(labels[b], color = nFaint, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.padding(top = 6.dp, start = 2.dp))
                    }
                    items(ns, key = { it.id }) { note -> NoteCard(vm, note) }
                }
            }
        }
    }
}

@Composable
private fun NoteCard(vm: AppViewModel, note: Note) {
    var text by remember(note.id) { mutableStateOf(note.text) }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(11.dp)).background(nPanel).padding(12.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            IconButton(onClick = { vm.toggleNote(note.id) }, modifier = Modifier.size(34.dp)) {
                Icon(if (note.done) Icons.Filled.CheckCircle else Icons.Outlined.Circle, "Toggle",
                    tint = if (note.done) nWorking else nFaint)
            }
            if (note.done) {
                Text(if (note.text.isEmpty()) "(empty)" else note.text, color = nFaint, fontSize = 15.sp,
                    textDecoration = TextDecoration.LineThrough,
                    modifier = Modifier.weight(1f).padding(start = 4.dp, top = 7.dp))
            } else {
                BasicTextField(
                    value = text,
                    onValueChange = { text = it; vm.updateNoteText(note.id, it) },
                    textStyle = TextStyle(color = nText, fontSize = 15.sp),
                    cursorBrush = SolidColor(nAccent),
                    modifier = Modifier.weight(1f).padding(start = 4.dp, top = 7.dp),
                    decorationBox = { inner ->
                        Box {
                            if (text.isEmpty()) Text("Write a note…", color = nFaint, fontSize = 15.sp)
                            inner()
                        }
                    }
                )
            }
            IconButton(onClick = { vm.deleteNote(note.id) }, modifier = Modifier.size(30.dp)) {
                Icon(Icons.Filled.Close, "Delete", tint = nFaint, modifier = Modifier.size(15.dp))
            }
        }
        Text(timeLabel(note.createdAt), color = nFaint.copy(alpha = 0.7f), fontSize = 10.sp,
            modifier = Modifier.padding(start = 38.dp, top = 2.dp))
    }
}
