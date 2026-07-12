package dev.universaltmux.android

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Themed colors (default Argus = the original values). @Composable getters so all the
// existing references resolve against the active theme.
private val ccInk: Color @Composable get() = LocalTheme.current.bg
private val ccPanel: Color @Composable get() = LocalTheme.current.panelAlt
private val ccText: Color @Composable get() = LocalTheme.current.text
private val ccDim: Color @Composable get() = LocalTheme.current.dim
private val ccFaint: Color @Composable get() = LocalTheme.current.faint
private val cWorking: Color @Composable get() = LocalTheme.current.working
private val cWaiting: Color @Composable get() = LocalTheme.current.waiting
private val cMilestone: Color @Composable get() = LocalTheme.current.milestone
private val cBad: Color @Composable get() = LocalTheme.current.bad
private val cLook: Color @Composable get() = LocalTheme.current.look
private val cDrift: Color @Composable get() = LocalTheme.current.unseen
private val cIdle: Color @Composable get() = LocalTheme.current.idle

private data class CCTile(val b: Broker, val s: SessionInfo, val st: AgentCardStatus?)

// The fixed sections, top to bottom. A card moves between these only when its status
// genuinely changes category — never from a flapping label or a text update, because
// the flappy labels (idle/look/milestone) all live in ONE section, and within a section
// cards are ordered by name (stable). So nothing shuffles ad-hoc while you watch.
private const val SEC_NEEDS = 0   // needs-decision, stuck — act now
private const val SEC_DONE = 1    // milestone, look, idle — finished / quiet
private const val SEC_WORKING = 2 // working, drifting — running on its own
private const val SEC_BACKLOG = 3 // set aside

private fun sectionFor(state: String, label: String?): Int = when (label) {
    "needs-decision", "stuck" -> SEC_NEEDS
    "working", "drifting", "no-progress" -> SEC_WORKING
    "milestone", "look", "idle" -> SEC_DONE
    else -> when (state) { "waiting" -> SEC_NEEDS; "working" -> SEC_WORKING; else -> SEC_DONE }
}

@Composable
private fun ccTint(state: String, label: String?): Color = when (label) {
    "needs-decision" -> cWaiting
    "look" -> cLook
    "stuck", "no-progress" -> cBad
    "drifting" -> cDrift
    "milestone" -> cMilestone
    "working" -> cWorking
    "idle" -> cIdle
    else -> when (state) { "waiting" -> cWaiting; "working" -> cWorking; else -> cIdle }
}

/** The DETERMINISTIC tmux state dot (mirrors the sidebar): blue=working,
 *  orange=finished-unseen, amber=waiting, grey=idle. Shown next to the model chip so a
 *  mess is visible at a glance even when the summary reads fine. */
@Composable
private fun stateDot(state: String, unseen: Boolean): Color = when {
    state == "working" -> cWorking
    unseen -> cDrift
    state == "waiting" -> cWaiting
    else -> cIdle
}

private fun ccChip(state: String, label: String?): String = when (label) {
    "needs-decision" -> "needs you"; "look" -> "worth a look"; "milestone" -> "milestone"
    "stuck" -> "stuck"; "drifting" -> "drifting"; "no-progress" -> "no progress"
    "working" -> "working"; "idle" -> "idle"
    else -> when (state) { "waiting" -> "needs you"; "working" -> "working"; else -> "idle" }
}

@Composable
fun CommandCenterScreen(vm: AppViewModel, onOpen: (Broker, String) -> Unit) {
    // Read observable state in the composable body (restartable scope) so the list
    // rebuilds when sessions / statuses / backlog change.
    val tiles = vm.brokers.toList().flatMap { b ->
        // Agent (ut spawn) and hidden sessions NEVER appear in the command center —
        // unconditionally, regardless of the "Show agent sessions" toggle (which only
        // affects the session list). This matches macOS, where the status agent also
        // never summarizes them, so they'd have no status anyway.
        vm.sessions[b.id].orEmpty().filter { !it.agent && !it.hidden }.map { s -> CCTile(b, s, vm.ccFor(b, s.name)) }
    }
    // Group into the fixed sections by CURRENT status; within a section order by name
    // (stable). A card only moves when its category actually changes — never ad-hoc.
    fun section(t: CCTile) = if (vm.isBacklogged(t.b, t.s.name)) SEC_BACKLOG else sectionFor(t.s.state, t.st?.label)
    val grouped = tiles.groupBy { section(it) }
    val labItems = vm.labAttention.toList()
    val sessionNeeds = grouped[SEC_NEEDS].orEmpty().size
    val needsCount = sessionNeeds + labItems.size
    val sections = listOf(
        SEC_NEEDS to "Needs you", SEC_DONE to "Done & idle", SEC_WORKING to "Working", SEC_BACKLOG to "Backlog",
    )

    LazyColumn(Modifier.fillMaxSize().background(ccInk).padding(horizontal = 12.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(top = 10.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Command Center", color = ccText, fontSize = 19.sp)
                Spacer(Modifier.width(10.dp))
                Text(
                    if (needsCount == 0) "all ${tiles.size} quiet" else "$needsCount need you · ${tiles.size - sessionNeeds} other",
                    color = if (needsCount == 0) ccFaint else cWaiting, fontSize = 12.sp,
                )
            }
        }
        if (tiles.isEmpty() && labItems.isEmpty()) {
            item {
                val engineOff = vm.engineStatus != "up"
                Text(
                    if (engineOff)
                        "Tailnet engine is \"${vm.engineStatus}\" — discovery is off, so there are no sessions.\n\nOpen ☰ (top-left) → Auth Key, paste your tailnet auth key, then tap \"Join & discover\".\n\n(The saved key gets cleared whenever the app is uninstalled/reinstalled — e.g. switching signing keys.)"
                    else
                        "No sessions found. Open ☰ to add a broker, or check that your brokers are running.",
                    color = ccDim, fontSize = 13.sp, modifier = Modifier.padding(24.dp),
                )
            }
        }
        sections.forEach { (sec, title) ->
            val cards = grouped[sec].orEmpty().sortedBy { it.s.name }
            val labCount = if (sec == SEC_NEEDS) labItems.size else 0
            if (cards.isNotEmpty() || labCount > 0) {
                item(key = "hdr-$sec") { CCHeader(title, cards.size + labCount) }
                if (sec == SEC_NEEDS) {
                    items(labItems, key = { "lab:${it.id}" }) { item ->
                        LabCCCard(item) { vm.openLabAttention(item.kind, item.targetID) }
                    }
                }
                items(cards, key = { it.b.id + "/" + it.s.name }) {
                    CCCard(vm, it, large = (sec == SEC_NEEDS), dim = (sec == SEC_BACKLOG), onOpen = onOpen)
                }
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun CCHeader(title: String, n: Int) {
    Row(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title.uppercase(), color = ccDim, fontSize = 11.sp)
        Spacer(Modifier.width(6.dp))
        Text("$n", color = ccFaint, fontSize = 11.sp)
    }
}

/** A deterministic protocol gate, visually related to a large CC card but not
 * pretending to be an inferred terminal status. */
@Composable
private fun LabCCCard(item: LabAttentionItem, onOpen: () -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.fillMaxWidth().padding(vertical = 4.dp)
            .background(ccPanel, shape)
            .border(1.dp, cWaiting.copy(alpha = 0.58f), shape)
            .clickable(onClick = onOpen)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(9.dp).background(cWaiting, RoundedCornerShape(5.dp)))
            Spacer(Modifier.width(8.dp))
            Icon(Icons.Filled.Science, null, tint = cWaiting, modifier = Modifier.size(17.dp))
            Spacer(Modifier.width(6.dp))
            Text(item.reference, color = ccText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(7.dp))
            Text(item.project, color = ccFaint, fontSize = 11.sp, maxLines = 1, modifier = Modifier.weight(1f))
            Text(
                if (item.kind == LabAttentionKind.KEY) "Lab access" else "Lab approval",
                color = cWaiting, fontSize = 11.sp,
                modifier = Modifier.background(cWaiting.copy(alpha = 0.16f), RoundedCornerShape(50))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            )
        }
        Text(item.summary, color = ccDim, fontSize = 13.sp, maxLines = 6,
            modifier = Modifier.padding(start = 17.dp, top = 8.dp))
        Row(Modifier.fillMaxWidth().padding(start = 17.dp, top = 7.dp)) {
            Text(item.machineName, color = ccFaint, fontSize = 11.sp, maxLines = 1, modifier = Modifier.weight(1f))
            Text("OPEN DECISION →", color = cWaiting, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CCCard(vm: AppViewModel, t: CCTile, large: Boolean, dim: Boolean = false, onOpen: (Broker, String) -> Unit) {
    val st = t.st
    val tint = ccTint(t.s.state, st?.label)
    val backlogged = vm.isBacklogged(t.b, t.s.name)
    val look = st?.lookAtThis
    val hasSummary = !st?.summary.isNullOrBlank()
    val summary = if (hasSummary) st!!.summary else "no status yet"
    var showMenu by remember { mutableStateOf(false) }
    if (showMenu) CCCardMenu(vm, t, onDismiss = { showMenu = false })
    Column(
        Modifier.fillMaxWidth().padding(vertical = 4.dp)
            .background(ccPanel, RoundedCornerShape(12.dp))
            .combinedClickable(onClick = { onOpen(t.b, t.s.name) }, onLongClick = { showMenu = true })
            .alpha(if (dim) 0.6f else 1f)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(9.dp).background(stateDot(t.s.state, vm.isUnseen(t.b, t.s.name)), RoundedCornerShape(5.dp)))
            Spacer(Modifier.width(8.dp))
            Text(t.s.name, color = ccText, fontSize = if (large) 16.sp else 15.sp, maxLines = 1, modifier = Modifier.weight(1f))
            Text(
                ccChip(t.s.state, st?.label), color = tint, fontSize = 11.sp,
                modifier = Modifier.background(tint.copy(alpha = 0.16f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 2.dp),
            )
            IconButton(onClick = { vm.toggleBacklog(t.b, t.s.name) }, modifier = Modifier.size(30.dp)) {
                Icon(
                    if (backlogged) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                    contentDescription = "Backlog", tint = if (backlogged) cMilestone else ccFaint,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        Text(t.b.name, color = ccFaint, fontSize = 11.sp, maxLines = 1, modifier = Modifier.padding(start = 17.dp))
        Spacer(Modifier.height(6.dp))
        Text(summary, color = if (hasSummary) ccDim else ccFaint, fontSize = if (large) 13.sp else 12.sp, maxLines = if (large) 6 else 4)
        if (large && !look.isNullOrBlank()) {
            Spacer(Modifier.height(6.dp))
            Text(
                look, color = ccText, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 4,
                modifier = Modifier.fillMaxWidth().background(tint.copy(alpha = 0.12f), RoundedCornerShape(6.dp)).padding(8.dp),
            )
        }
    }
}

// The labels offered in the long-press "Set status" menu (mirrors the macOS menu).
private val CC_STATUS_OPTIONS = listOf(
    "working" to "Working",
    "idle" to "Idle",
    "needs-decision" to "Needs you",
    "stuck" to "Stuck",
    "milestone" to "Milestone",
    "look" to "Worth a look",
    "drifting" to "Drifting",
)

/** Long-press menu for a command-center card: set its status (synced to the Mac, which
 *  applies it and re-publishes) or toggle backlog (a local per-device choice). */
@Composable
private fun CCCardMenu(vm: AppViewModel, t: CCTile, onDismiss: () -> Unit) {
    val current = t.st?.label
    val backlogged = vm.isBacklogged(t.b, t.s.name)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = ccPanel,
        title = { Text(t.s.name, color = ccText, fontSize = 16.sp, maxLines = 1) },
        text = {
            Column {
                Text("SET STATUS", color = ccDim, fontSize = 11.sp, modifier = Modifier.padding(bottom = 2.dp))
                CC_STATUS_OPTIONS.forEach { (lbl, name) ->
                    val sel = lbl == current
                    Text(
                        (if (sel) "● " else "    ") + name,
                        color = if (sel) cMilestone else ccText, fontSize = 15.sp,
                        modifier = Modifier.fillMaxWidth()
                            .clickable { vm.setManualStatus(t.b, t.s.name, lbl); onDismiss() }
                            .padding(vertical = 9.dp),
                    )
                }
                Divider(color = ccFaint.copy(alpha = 0.3f), modifier = Modifier.padding(vertical = 4.dp))
                Text(
                    if (backlogged) "Remove from backlog" else "Backlog — set aside",
                    color = ccText, fontSize = 15.sp,
                    modifier = Modifier.fillMaxWidth()
                        .clickable { vm.toggleBacklog(t.b, t.s.name); onDismiss() }
                        .padding(vertical = 9.dp),
                )
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel", color = ccDim) } },
    )
}
