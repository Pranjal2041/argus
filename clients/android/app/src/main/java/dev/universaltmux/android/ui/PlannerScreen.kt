package dev.universaltmux.android

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter

const val SCREEN_PLANNER = 9
const val SCREEN_WORKSPACE = 10

@Composable
fun PlannerScreen(vm: AppViewModel) {
    val theme = LocalTheme.current
    val zone = ZoneId.systemDefault()
    var anchorText by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    val anchor = LocalDate.parse(anchorText)
    var project by rememberSaveable { mutableStateOf("") }
    var hideCompleted by rememberSaveable { mutableStateOf(false) }
    var editing by remember { mutableStateOf<PlannerCommitment?>(null) }
    var creating by remember { mutableStateOf(false) }
    val filtered = vm.planner.filter { (!hideCompleted || !it.isCompleted) && (project.isBlank() || it.project.contains(project, true)) }
        .sortedWith(compareBy<PlannerCommitment> { it.effectiveDeadline(zone) }.thenBy { it.createdAt }.thenBy { it.id })
    val visible = filtered.filter {
        val date = Instant.parse(it.deadline).atZone(zone).toLocalDate()
        (date >= anchor && date < anchor.plusDays(7)) || (anchor == LocalDate.now() && date < anchor && !it.isCompleted)
    }
    Column(Modifier.fillMaxSize().background(theme.bg)) {
        WorkspaceSyncBanner(vm, "planner")
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Finish lines", color = theme.text, fontSize = 25.sp, fontWeight = FontWeight.SemiBold)
                    Text("${visible.count { !it.isCompleted }} open · next seven days", color = theme.dim, fontSize = 12.sp)
                }
                FilledTonalIconButton(onClick = { creating = true }) { Icon(Icons.Default.Add, "Add plan") }
            }
            OutlinedTextField(project, { project = it }, label = { Text("Filter projects") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { anchorText = anchor.minusDays(7).toString() }) { Icon(Icons.Default.ChevronLeft, "Previous week") }
                Text(anchor.format(DateTimeFormatter.ofPattern("MMM d")) + " – " + anchor.plusDays(6).format(DateTimeFormatter.ofPattern("MMM d")),
                    color = theme.text, modifier = Modifier.weight(1f))
                TextButton(onClick = { anchorText = LocalDate.now().toString() }) { Text("Today") }
                IconButton(onClick = { anchorText = anchor.plusDays(7).toString() }) { Icon(Icons.Default.ChevronRight, "Next week") }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(hideCompleted, { hideCompleted = it }); Text("Hide completed", color = theme.dim, fontSize = 13.sp)
            }
        }
        if (visible.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("No plans in this window.\nAdd a finish line to get started.", color = theme.dim, modifier = Modifier.padding(24.dp))
        } else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val groups = visible.groupBy {
                val day = Instant.parse(it.deadline).atZone(zone).toLocalDate()
                if (day < anchor) "Overdue" else day.format(DateTimeFormatter.ofPattern("EEEE, MMM d"))
            }
            groups.forEach { (day, plans) ->
                item(key = "day:$day") { Text(day, color = if (day == "Overdue") theme.waiting else theme.accent, fontSize = 12.sp, modifier = Modifier.padding(top = 10.dp, bottom = 4.dp)) }
                items(plans, key = { it.id }) { plan ->
                    Card(Modifier.fillMaxWidth().clickable { editing = plan }, colors = CardDefaults.cardColors(containerColor = theme.panel)) {
                        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(plan.isCompleted, { vm.togglePlan(plan) })
                            Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                                Text(plan.title, color = if (plan.isCompleted) theme.dim else theme.text, fontSize = 15.sp)
                                val time = if (plan.hasExactTime) Instant.parse(plan.deadline).atZone(zone).format(DateTimeFormatter.ofPattern("h:mm a")) else "End of day"
                                Text(listOf(plan.project, time).filter { it.isNotEmpty() }.joinToString(" · "), color = theme.dim, fontSize = 12.sp)
                            }
                            Icon(Icons.Default.ChevronRight, "Edit plan", tint = theme.faint)
                        }
                    }
                }
            }
        }
    }
    if (creating || editing != null) {
        val original = editing
        PlannerEditor(original, onDismiss = { creating = false; editing = null }, onSave = {
            vm.savePlan(it); creating = false; editing = null
        }, onDelete = { if (original != null) vm.deletePlan(original); creating = false; editing = null })
    }
}

@Composable
private fun PlannerEditor(original: PlannerCommitment?, onDismiss: () -> Unit, onSave: (PlannerCommitment) -> Unit, onDelete: () -> Unit) {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    val initial = original ?: PlannerCommitment(deadline = LocalDate.now().atTime(23, 59).atZone(zone).toInstant().toString())
    var title by remember { mutableStateOf(initial.title) }
    var project by remember { mutableStateOf(initial.project) }
    var date by remember { mutableStateOf(Instant.parse(initial.deadline).atZone(zone)) }
    var exact by remember { mutableStateOf(initial.hasExactTime) }
    var confirmDelete by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (original == null) "New finish line" else "Edit finish line") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(title, { title = it }, label = { Text("What would you finish?") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(project, { project = it }, label = { Text("Project") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedButton(onClick = {
                DatePickerDialog(context, { _, year, month, day -> date = date.withYear(year).withMonth(month + 1).withDayOfMonth(day) }, date.year, date.monthValue - 1, date.dayOfMonth).show()
            }) { Text(date.format(DateTimeFormatter.ofPattern("EEE, MMM d, yyyy"))) }
            Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(exact, { exact = it }); Text("Exact time") }
            if (exact) OutlinedButton(onClick = {
                TimePickerDialog(context, { _, hour, minute -> date = date.withHour(hour).withMinute(minute).withSecond(0) }, date.hour, date.minute, false).show()
            }) { Text(date.format(DateTimeFormatter.ofPattern("h:mm a"))) }
            if (original != null) TextButton(onClick = { confirmDelete = true }) { Text("Delete plan", color = MaterialTheme.colorScheme.error) }
        }
    }, confirmButton = { TextButton(enabled = title.isNotBlank(), onClick = {
        val deadline = if (exact) date.toInstant() else date.toLocalDate().atStartOfDay(zone).toInstant()
        onSave(initial.copy(title = title, project = project, deadline = deadline.toString(), hasExactTime = exact))
    }) { Text("Save") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
    if (confirmDelete) AlertDialog(onDismissRequest = { confirmDelete = false }, title = { Text("Delete this plan?") },
        confirmButton = { TextButton(onClick = onDelete) { Text("Delete") } }, dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } })
}
