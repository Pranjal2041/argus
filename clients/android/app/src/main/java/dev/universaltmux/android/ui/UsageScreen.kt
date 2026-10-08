package dev.universaltmux.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date
import java.util.UUID

const val SCREEN_USAGE = 11
internal fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).mapNotNull(::optJSONObject)
internal fun workspaceDate(millis: Long): String = if (millis <= 0) "Not yet collected" else DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(millis))
internal fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).mapNotNull { optString(it).takeIf(String::isNotEmpty) }
internal fun usageCardKeys(card: JSONObject): List<String> {
    val identity = card.optJSONObject("ordering") ?: return listOf("card:" + card.optString("id"))
    return (listOfNotNull(identity.optString("primary").takeIf { it.isNotEmpty() && it != "null" }) + identity.optJSONArray("members").strings()).distinct()
}
internal fun orderedUsageCards(cards: List<JSONObject>, settings: JSONObject?): List<JSONObject> {
    val ranks = settings?.optJSONArray("cardOrder").strings().withIndex().associate { it.value to it.index }
    return cards.sortedBy { card ->
        val keys = usageCardKeys(card); ranks[keys.firstOrNull()] ?: keys.mapNotNull { ranks[it] }.minOrNull() ?: Int.MAX_VALUE
    }
}
internal fun usageWarningVisible(warning: JSONObject, dismissals: JSONObject?, now: Long): Boolean {
    if (warning.has("resetsAt") && warning.optLong("resetsAt") <= now) return false
    val dismissed = dismissals?.optJSONObject(warning.optString("id")) ?: return true
    return dismissed.optString("cycle") != warning.optString("cycle") ||
        (warning.optBoolean("critical") && !dismissed.optBoolean("critical")) ||
        (dismissed.has("expiresAt") && dismissed.optLong("expiresAt") <= now)
}

@Composable
fun UsageGlances(vm: AppViewModel, onOpen: () -> Unit) {
    val snapshot = vm.workspace.data("usage", "current")
    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Usage", color = LocalTheme.current.text, fontSize = 17.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onOpen) { Text("All usage") }
        }
        if (snapshot == null) Text("Waiting for the workspace collector", color = LocalTheme.current.dim, fontSize = 12.sp)
        else {
            Text("Updated ${workspaceDate(snapshot.optLong("lastRefresh"))}", color = LocalTheme.current.dim, fontSize = 11.sp)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                orderedUsageCards(snapshot.optJSONArray("glances").objects(), vm.workspace.data("usage-settings", "default")).forEach { metric -> UsageMetric(metric, Modifier.width(218.dp).clickable(onClick = onOpen)) }
            }
        }
    }
}

@Composable
private fun UsageMetric(metric: JSONObject, modifier: Modifier = Modifier) {
    Card(modifier) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(metric.optString("title"), fontSize = 12.sp)
            Text(metric.optString("value"), fontSize = 24.sp)
            Text(metric.optString("detail"), fontSize = 11.sp)
            if (metric.has("remaining")) LinearProgressIndicator(progress = (metric.optDouble("remaining") / 100).toFloat().coerceIn(0f, 1f), modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
fun UsageScreen(vm: AppViewModel) {
    val snapshot = vm.workspace.data("usage", "current")
    val settings = vm.workspace.data("usage-settings", "default")
    var query by rememberSaveable { mutableStateOf("") }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    var connectionsOpen by rememberSaveable { mutableStateOf(false) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val accounts = snapshot?.optJSONArray("accounts").objects()
    val queued = vm.workspace.collection("commands").any { it.data?.optString("kind") == "usage-refresh" }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Usage", fontSize = 27.sp, color = LocalTheme.current.text, modifier = Modifier.weight(1f))
                TextButton(onClick = { settingsOpen = true }, enabled = settings != null) { Text("Settings") }
                TextButton(onClick = { vm.changeShared("commands", UUID.randomUUID().toString(), JSONObject().put("kind", "usage-refresh")) }, enabled = vm.workspace.loaded && !queued) { Text(if (queued) "Queued" else "Refresh") }
            }
            Text("${accounts.size} accounts & devices · ${workspaceDate(snapshot?.optLong("lastRefresh") ?: 0)}", color = LocalTheme.current.dim, fontSize = 12.sp)
            TextButton(onClick = { connectionsOpen = true }) { Text("Manage connections") }
            val freshFor = maxOf(300.0, (settings?.optDouble("refreshSeconds", 120.0) ?: 120.0) * 3) * 1000
            if (snapshot != null && System.currentTimeMillis() - snapshot.optLong("lastRefresh") > freshFor) Text("Cached readings · waiting for the collector", color = LocalTheme.current.waiting, fontSize = 12.sp)
            (vm.workspaceSelectionIssue ?: vm.workspace.issue)?.let { Text(it, color = LocalTheme.current.waiting, fontSize = 12.sp) }
        }
        if (snapshot == null) item { Text("Usage appears here when the workspace's background service publishes its first reading.", color = LocalTheme.current.dim) }
        val warnings = snapshot?.optJSONArray("warnings").objects().filter { usageWarningVisible(it, vm.workspace.data("usage-dismissals", "default"), System.currentTimeMillis()) }
        items(warnings, key = { "warning-${it.optString("id")}" }) { warning ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(warning.optString("title"), color = LocalTheme.current.waiting)
                    Text(warning.optString("detail"), fontSize = 12.sp)
                    if (warning.has("resetsAt")) Text("Resets ${workspaceDate(warning.optLong("resetsAt"))}", fontSize = 11.sp)
                    Row {
                        TextButton(onClick = { selected = warning.optString("sourceID") }) { Text("View") }
                        TextButton(onClick = { dismissUsage(vm, warning, false) }) { Text("Dismiss") }
                        TextButton(onClick = { dismissUsage(vm, warning, true) }) { Text("Snooze") }
                    }
                }
            }
        }
        items(snapshot?.optJSONArray("failures").objects(), key = { "failure-${it.optString("sourceID", it.optString("integration"))}" }) { failure ->
            Text(failure.optString("message"), color = LocalTheme.current.waiting, fontSize = 12.sp)
        }
        item { OutlinedTextField(query, { query = it }, label = { Text("Find an account or device") }, modifier = Modifier.fillMaxWidth(), singleLine = true) }
        items(accounts.filter { (it.optString("title") + " " + it.optString("account")).contains(query, true) }, key = { it.optString("id") }) { account ->
            Card(Modifier.fillMaxWidth().clickable { selected = account.optString("id") }) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(account.optString("title"), fontSize = 18.sp)
                    Text(account.optString("account"), fontSize = 13.sp)
                    Text("${account.optString("status")} · ${if (account.optBoolean("stale")) "cached · " else ""}${workspaceDate(account.optLong("observedAt"))}", fontSize = 11.sp)
                    account.optJSONArray("cards").objects().forEach { metric ->
                        Text("${metric.optString("value")} · ${metric.optString("detail")}", fontSize = 13.sp)
                    }
                }
            }
        }
    }
    if (connectionsOpen) UsageConnections(vm) { connectionsOpen = false }
    if (settingsOpen && settings != null) UsageSettings(vm, settings) { settingsOpen = false }
    val source = snapshot?.optJSONArray("sources").objects().firstOrNull { it.optString("id") == selected }
    if (selected != null && source != null) AlertDialog(onDismissRequest = { selected = null }, title = { Text(source.optString("account")) }, text = {
        Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            // The detail viewer follows normalized metric fields, not provider
            // payloads; new collectors remain inspectable on older clients.
            usageDetailRows(source.optJSONObject("payload") ?: JSONObject()).forEach { (label, value) ->
                Text(label, fontSize = 11.sp, color = LocalTheme.current.dim)
                Text(value, fontSize = 14.sp)
            }
        }
    }, confirmButton = { TextButton(onClick = { selected = null }) { Text("Done") } })
}

internal fun usageDetailRows(value: JSONObject, prefix: String = ""): List<Pair<String, String>> = buildList {
    value.keys().forEach { key ->
        if (key == "id") return@forEach
        val label = if (key == "_0") prefix else listOf(prefix, key.replace(Regex("([a-z])([A-Z])"), "$1 $2")).filter { it.isNotEmpty() }.joinToString(" · ")
        when (val child = value.opt(key)) {
            is JSONObject -> addAll(usageDetailRows(child, label))
            is JSONArray -> {
                for (i in 0 until child.length()) {
                    val row = child.opt(i)
                    if (row is JSONObject) addAll(usageDetailRows(row, "$label ${i + 1}"))
                    else if (row != JSONObject.NULL) add("$label ${i + 1}" to row.toString())
                }
            }
            JSONObject.NULL, null -> Unit
            is Number -> add(label to if (key.endsWith("At") || key.endsWith("Through")) workspaceDate(child.toLong()) else child.toString())
            else -> add(label to child.toString())
        }
    }
}

private fun dismissUsage(vm: AppViewModel, warning: JSONObject, snooze: Boolean) {
    val dismissals = JSONObject(vm.workspace.data("usage-dismissals", "default")?.toString() ?: "{}")
    val value = JSONObject().put("cycle", warning.optString("cycle")).put("critical", warning.optBoolean("critical"))
    if (snooze) {
        val hours = vm.workspace.data("usage-settings", "default")?.optJSONObject("policy")?.optDouble("snoozeHours", 4.0) ?: 4.0
        value.put("expiresAt", System.currentTimeMillis() + (hours * 3_600_000).toLong())
    }
    dismissals.put(warning.optString("id"), value)
    vm.changeShared("usage-dismissals", "default", dismissals)
}

@Composable
private fun UsageSettings(vm: AppViewModel, settings: JSONObject, close: () -> Unit) {
    fun edit(change: (JSONObject) -> Unit) {
        val next = JSONObject(settings.toString()); change(next); vm.changeShared("usage-settings", "default", next)
    }
    val policy = settings.optJSONObject("policy") ?: JSONObject()
    AlertDialog(onDismissRequest = close, title = { Text("Usage settings") }, text = {
        Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            listOf("enabled" to "Show warnings", "quotaEnabled" to "Quota warnings", "budgetEnabled" to "Budget warnings", "storageEnabled" to "Storage warnings", "includeModelLimits" to "Model-specific limits").forEach { (key, title) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(title, Modifier.weight(1f)); Switch(policy.optBoolean(key), { enabled -> edit { it.getJSONObject("policy").put(key, enabled) } })
                }
            }
            listOf("quotaRemaining" to "Quota remaining", "budgetRemaining" to "Budget remaining", "storageRemaining" to "Storage remaining").forEach { (key, title) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("$title ≤ ${policy.optInt(key, 10)}%", Modifier.weight(1f), fontSize = 12.sp)
                    TextButton(onClick = { edit { it.getJSONObject("policy").put(key, (policy.optInt(key, 10) - 5).coerceAtLeast(0)) } }) { Text("−") }
                    TextButton(onClick = { edit { it.getJSONObject("policy").put(key, (policy.optInt(key, 10) + 5).coerceAtMost(100)) } }) { Text("+") }
                }
            }
            Text("Refresh interval", fontSize = 12.sp)
            Row { listOf(60, 120, 300, 900).forEach { seconds ->
                TextButton(onClick = { edit { it.put("refreshSeconds", seconds) } }) { Text("${if (settings.optInt("refreshSeconds") == seconds) "✓" else ""}${seconds / 60}m") }
            } }
            Text("Snooze duration", fontSize = 12.sp)
            Row { listOf(1, 4, 12, 24).forEach { hours -> TextButton(onClick = { edit { it.getJSONObject("policy").put("snoozeHours", hours) } }) { Text("${if (policy.optInt("snoozeHours", 4) == hours) "✓" else ""}${hours}h") } } }
            Text("Account warnings", fontSize = 12.sp)
            vm.workspace.data("usage", "current")?.optJSONArray("accounts").objects().forEach { account ->
                val id = account.optString("id"); val muted = policy.optJSONArray("mutedSources").strings()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(account.optString("account"), Modifier.weight(1f), fontSize = 12.sp)
                    Switch(id !in muted, { enabled -> edit { it.getJSONObject("policy").put("mutedSources", JSONArray(if (enabled) muted - id else (muted + id).distinct())) } })
                }
            }
            Text("Command Center card order", fontSize = 12.sp)
            val cards = orderedUsageCards(vm.workspace.data("usage", "current")?.optJSONArray("glances").objects(), settings)
            cards.forEachIndexed { index, card ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(card.optString("title"), Modifier.weight(1f), fontSize = 12.sp)
                    TextButton(enabled = index > 0, onClick = {
                        val reordered = cards.toMutableList().apply { add(index - 1, removeAt(index)) }
                        val visible = cards.flatMap(::usageCardKeys).toSet()
                        val replacement = reordered.flatMap(::usageCardKeys).distinct().iterator()
                        val keys = settings.optJSONArray("cardOrder").strings().mapNotNull { key -> if (key !in visible) key else if (replacement.hasNext()) replacement.next() else null }.toMutableList()
                        while (replacement.hasNext()) keys.add(replacement.next())
                        edit { it.put("cardOrder", JSONArray(keys.distinct())) }
                    }) { Text("↑") }
                }
            }
            TextButton(onClick = { edit { it.put("cardOrder", JSONArray()) } }) { Text("Reset card order") }
            TextButton(onClick = { vm.changeShared("usage-dismissals", "default", JSONObject()) }) { Text("Restore dismissed warnings") }
        }
    }, confirmButton = { TextButton(onClick = close) { Text("Done") } })
}
