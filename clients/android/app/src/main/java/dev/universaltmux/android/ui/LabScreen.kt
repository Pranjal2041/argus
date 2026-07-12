package dev.universaltmux.android

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Duration
import java.time.Instant
import java.util.Locale

// Native Android Lab: an industrial research ledger in the app's selected
// palette. Dense evidence uses monospace; human decisions stay large and calm.
private val labInk: Color @Composable get() = LocalTheme.current.bg
private val labPanel: Color @Composable get() = LocalTheme.current.panelAlt
private val labSurface: Color @Composable get() = LocalTheme.current.panel
private val labText: Color @Composable get() = LocalTheme.current.text
private val labDim: Color @Composable get() = LocalTheme.current.dim
private val labFaint: Color @Composable get() = LocalTheme.current.faint
private val labBorder: Color @Composable get() = LocalTheme.current.border
private val labAccent: Color @Composable get() = LocalTheme.current.accent
private val labSuccess: Color @Composable get() = LocalTheme.current.milestone
private val labRunning: Color @Composable get() = LocalTheme.current.working
private val labWaiting: Color @Composable get() = LocalTheme.current.waiting
private val labDanger: Color @Composable get() = LocalTheme.current.bad

@Composable
fun LabScreen(vm: AppViewModel, onOpenTerminal: (Broker, String) -> Unit) {
    val route = vm.labRoute
    Column(Modifier.fillMaxSize().background(labInk)) {
        LabMasthead(vm, route)
        vm.labError?.let { message ->
            Row(
                Modifier.fillMaxWidth().background(labDanger.copy(alpha = 0.12f))
                    .clickable { vm.clearLabError() }.padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(message, color = labDanger, fontSize = 12.sp, modifier = Modifier.weight(1f))
                Icon(Icons.Filled.Close, "Dismiss", tint = labDanger, modifier = Modifier.size(16.dp))
            }
        }
        when {
            route.area == LabArea.INBOX && route.targetID.isNotEmpty() ->
                LabDecisionDetail(vm, route, onOpenTerminal)
            route.area == LabArea.RESEARCH && route.cardID.isNotEmpty() &&
                route.compareRunA.isNotEmpty() && route.compareRunB.isNotEmpty() ->
                LabComparePage(vm, route.cardID, route.compareRunA, route.compareRunB)
            route.area == LabArea.RESEARCH && route.cardID.isNotEmpty() && route.runID.isNotEmpty() ->
                LabRunPage(vm, route.cardID, route.runID, onOpenTerminal)
            route.area == LabArea.RESEARCH && route.cardID.isNotEmpty() ->
                LabSetPage(vm, route.cardID)
            route.area == LabArea.INBOX -> LabInbox(vm)
            route.area == LabArea.RESEARCH -> LabResearch(vm)
            else -> LabGuidance(vm)
        }
    }
}

@Composable
private fun LabMasthead(vm: AppViewModel, route: LabRoute) {
    Column(Modifier.fillMaxWidth().background(labSurface)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 7.dp, top = 10.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(26.dp).clip(CircleShape).border(1.dp, labAccent, CircleShape),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.Science, null, tint = labAccent, modifier = Modifier.size(15.dp)) }
            Spacer(Modifier.width(9.dp))
            Text("LAB", color = labText, fontSize = 16.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
            Text("  /  ARGUS", color = labFaint, fontSize = 11.sp, letterSpacing = 1.sp)
            Spacer(Modifier.weight(1f))
            if (vm.labRefreshing) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 1.5.dp, color = labAccent)
            IconButton(onClick = { vm.refreshLab() }) { Icon(Icons.Filled.Refresh, "Refresh Lab", tint = labDim) }
        }
        val isDetail = route.targetID.isNotEmpty() || route.cardID.isNotEmpty()
        if (!isDetail) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 9.dp)) {
                LabTab("INBOX", route.area == LabArea.INBOX, vm.labAttention.size) { vm.setLabArea(LabArea.INBOX) }
                LabTab("RESEARCH", route.area == LabArea.RESEARCH, 0) { vm.setLabArea(LabArea.RESEARCH) }
                LabTab("GUIDANCE", route.area == LabArea.GUIDANCE, 0) { vm.setLabArea(LabArea.GUIDANCE) }
            }
        }
        HorizontalDivider(color = labBorder.copy(alpha = 0.7f))
    }
}

@Composable
private fun RowScope.LabTab(label: String, selected: Boolean, count: Int, onClick: () -> Unit) {
    Column(
        Modifier.weight(1f).clickable(onClick = onClick).padding(top = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = if (selected) labText else labFaint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            if (count > 0) {
                Spacer(Modifier.width(5.dp))
                Text("$count", color = labInk, fontSize = 9.sp,
                    modifier = Modifier.background(labWaiting, CircleShape).padding(horizontal = 6.dp, vertical = 1.dp))
            }
        }
        Spacer(Modifier.height(7.dp))
        Box(Modifier.fillMaxWidth().height(2.dp).background(if (selected) labAccent else Color.Transparent))
    }
}

@Composable
private fun LabInbox(vm: AppViewModel) {
    val items = vm.labAttention.toList()
    if (!vm.labLoaded && vm.labRefreshing) {
        LabCentered("Reading Lab stores…")
    } else if (items.isEmpty()) {
        LabEmpty("Decision queue clear", "No access request or experiment is waiting on you.")
    } else {
        LazyColumn(
            Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            item { LabSectionLabel("OLDEST REQUEST FIRST", detail = "${items.size} blocked") }
            items(items, key = { it.id }) { item ->
                LabDecisionRow(item) { vm.openLabAttention(item.kind, item.targetID) }
            }
            item { Spacer(Modifier.height(18.dp)) }
        }
    }
}

@Composable
private fun LabDecisionRow(item: LabAttentionItem, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(labPanel).clickable(onClick = onClick)
            .border(1.dp, labWaiting.copy(alpha = 0.32f), shape).padding(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.width(3.dp).height(54.dp).background(labWaiting, RoundedCornerShape(2.dp)))
        Spacer(Modifier.width(11.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (item.kind == LabAttentionKind.KEY) "ACCESS" else "EXPERIMENT",
                    color = labWaiting, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
                Spacer(Modifier.width(8.dp))
                Text(item.reference, color = labText, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                Spacer(Modifier.weight(1f))
                Text(ago(item.created), color = labFaint, fontSize = 10.sp)
            }
            Text(item.summary, color = labText, fontSize = 14.sp, maxLines = 3, modifier = Modifier.padding(top = 5.dp))
            Text("${item.project}  /  ${item.machineName}", color = labFaint, fontSize = 11.sp,
                maxLines = 1, modifier = Modifier.padding(top = 5.dp))
        }
    }
}

@Composable
private fun LabDecisionDetail(vm: AppViewModel, route: LabRoute, onOpenTerminal: (Broker, String) -> Unit) {
    when (route.attentionKind) {
        LabAttentionKind.KEY -> {
            val item = vm.labPendingKeys.firstOrNull { it.id == route.targetID }
            if (item == null) LabResolved { vm.setLabArea(LabArea.INBOX) }
            else LabAccessDossier(vm, item, onOpenTerminal)
        }
        LabAttentionKind.PROPOSAL -> {
            val item = vm.labPendingRuns.firstOrNull { it.id == route.targetID }
            if (item == null) LabResolved { vm.setLabArea(LabArea.INBOX) }
            else {
                val card = vm.labSets.firstOrNull {
                    it.storeID == item.storeID && it.brief.set.id == item.proposal.set
                }
                if (card == null) LabEmpty("Set unavailable", "The proposal exists, but its owning set is not reachable.")
                else LabProposalDossier(vm, item, card, onOpenTerminal)
            }
        }
        null -> LabResolved { vm.setLabArea(LabArea.INBOX) }
    }
}

@Composable
private fun LabAccessDossier(vm: AppViewModel, item: LabPendingKey, onOpenTerminal: (Broker, String) -> Unit) {
    var project by remember(item.id) { mutableStateOf(item.key.project) }
    var denial by remember(item.id) { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        LabBackBar("ACCESS REQUEST", "agent boundary") { vm.setLabArea(LabArea.INBOX) }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(14.dp)) {
            Text("An agent wants a research set.", color = labText, fontSize = 25.sp, fontWeight = FontWeight.Bold)
            Text("Approval creates one machine-bound key and one isolated set. It grants no access to another agent's record.",
                color = labDim, fontSize = 14.sp, modifier = Modifier.padding(top = 8.dp, bottom = 18.dp))
            LabFacts(
                listOf(
                    "MACHINE" to item.machineName,
                    "FOLDER" to item.key.cwd,
                    "SESSION" to item.key.session.orEmpty().ifEmpty { "not reported" },
                    "REQUESTED" to ago(item.key.created),
                ),
            )
            Spacer(Modifier.height(14.dp))
            OutlinedTextField(project, { project = it }, label = { Text("Project label") },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(denial, { denial = it }, label = { Text("Optional note if denied") },
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
            item.key.session?.takeIf(String::isNotEmpty)?.let { session ->
                TextButton(onClick = { onOpenTerminal(item.broker, session) }, modifier = Modifier.padding(top = 8.dp)) {
                    Icon(Icons.Filled.Terminal, null); Spacer(Modifier.width(6.dp)); Text("Open agent terminal")
                }
            }
        }
        LabDecisionDock(
            busy = vm.labActionBusy,
            rejectLabel = "Deny",
            onReject = { vm.decideLabKey(item, false, project, denial) },
            onApprove = { vm.decideLabKey(item, true, project) },
        )
    }
}

@Composable
private fun LabProposalDossier(
    vm: AppViewModel,
    item: LabPendingRun,
    card: LabSetCard,
    onOpenTerminal: (Broker, String) -> Unit,
) {
    val key = vm.labDetailKey(card, item.proposal.run)
    val detail = vm.labDetails[key]
    var note by remember(item.id) { mutableStateOf("") }
    LaunchedEffect(key) { vm.loadLabDetail(card, item.proposal.run) }
    Column(Modifier.fillMaxSize()) {
        LabBackBar("EXPERIMENT APPROVAL", item.proposal.run) { vm.setLabArea(LabArea.INBOX) }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(14.dp)) {
            Text(item.proposal.intent.ifBlank { "Proposed experiment" }, color = labText,
                fontSize = 23.sp, fontWeight = FontWeight.Bold)
            LabMetaLine(card, item.proposal.tier, item.proposal.group)
            Spacer(Modifier.height(16.dp))
            LabApprovalEnvelope(detail, item.proposal)
            detail?.envelope?.tmuxSession?.takeIf(String::isNotEmpty)?.let { session ->
                TextButton(onClick = { onOpenTerminal(card.broker, session) }) {
                    Icon(Icons.Filled.Terminal, null); Spacer(Modifier.width(6.dp)); Text("Open source terminal")
                }
            }
            OutlinedTextField(note, { note = it }, label = { Text("Optional message to the agent") },
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
        }
        LabDecisionDock(
            busy = vm.labActionBusy,
            rejectLabel = "Reject",
            onReject = { vm.decideLabRun(card, item.proposal.run, false, note) },
            onApprove = { vm.decideLabRun(card, item.proposal.run, true, note) },
        )
    }
}

@Composable
private fun LabApprovalEnvelope(detail: LabRunDetail?, proposal: LabProposal) {
    val env = detail?.envelope
    val snapshot = env?.snapshot
    LabLedgerCard(accent = labWaiting) {
        LabSectionLabel("APPROVAL ENVELOPE", detail = "bound to exact evidence")
        if (detail == null) {
            LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 20.dp), color = labAccent)
        } else {
            LabFacts(
                listOf(
                    "COMMAND" to (env?.argv?.firstOrNull() ?: proposal.argv.firstOrNull().orEmpty()).ifEmpty { "missing" },
                    "CODE" to when { snapshot?.noGit == true -> "no repository"; !snapshot?.baseSha.isNullOrEmpty() -> snapshot!!.baseSha!!.take(10); else -> "not captured" },
                    "CHANGES" to if ((snapshot?.patchBytes ?: 0) > 0) "${snapshot?.patchBytes} B diff" else "clean tree",
                    "PARAMETERS" to "${env?.params?.size ?: 0} files",
                    "DECLARED DATA" to "${env?.dataFiles?.size ?: 0} fingerprints",
                ),
            )
            val argv = env?.argv?.ifEmpty { proposal.argv } ?: proposal.argv
            if (argv.isNotEmpty()) LabCode(argv.joinToString(" "), Modifier.padding(top = 12.dp))
            detail.textByName.entries.filter { it.key.startsWith("files/") }.forEach { (name, text) ->
                LabEvidence(name, text)
            }
            detail.textByName["snapshot/diff.patch"]?.let { LabEvidence("UNCOMMITTED CODE", it) }
        }
    }
}

@Composable
private fun LabResearch(vm: AppViewModel) {
    var showArchived by remember { mutableStateOf(false) }
    val cards = vm.labSets.filter { showArchived || !it.brief.archived }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 13.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("RESEARCH INDEX", color = labFaint, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp)
            Spacer(Modifier.weight(1f))
            Text(if (showArchived) "SHOWING ARCHIVE" else "ACTIVE", color = if (showArchived) labWaiting else labSuccess,
                fontSize = 10.sp, modifier = Modifier.clickable { showArchived = !showArchived }.padding(6.dp))
        }
        if (cards.isEmpty()) {
            LabEmpty("No experiment sets", if (showArchived) "The archive is empty." else "Approved agents have not recorded a set yet.")
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                cards.groupBy { it.brief.set.project }.toSortedMap().forEach { (project, projectCards) ->
                    item("project:$project") { LabSectionLabel(project.uppercase(), detail = "${projectCards.size} sets") }
                    items(projectCards.sortedByDescending { it.brief.set.created }, key = { it.id }) { card ->
                        LabSetRow(card) { vm.openLabSet(card.id) }
                    }
                }
                item { Spacer(Modifier.height(18.dp)) }
            }
        }
    }
}

@Composable
private fun LabSetRow(card: LabSetCard, onClick: () -> Unit) {
    val active = card.brief.runs.count { runStatus(it).first in setOf("running", "needs", "approved") && !it.archived }
    val statusColors = card.brief.runs.filterNot { it.archived }.map { runStatus(it).second }.distinct()
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(labPanel).clickable(onClick = onClick)
            .padding(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            if (statusColors.isEmpty()) Box(Modifier.size(7.dp).background(labFaint, CircleShape))
            statusColors.take(4).forEach { Box(Modifier.size(7.dp).background(it, CircleShape)) }
        }
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(card.machineName, color = labText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                if (card.offline) { Spacer(Modifier.width(6.dp)); LabTag("OFFLINE", labFaint) }
            }
            Text("${card.brief.set.id}  /  ${shortPath(card.brief.set.cwd)}", color = labFaint,
                fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1)
        }
        Text(if (active > 0) "$active ACTIVE" else "${card.brief.runs.size} RUNS",
            color = if (active > 0) labRunning else labFaint, fontSize = 10.sp)
    }
}

@Composable
private fun LabSetPage(vm: AppViewModel, cardID: String) {
    val card = vm.labSets.firstOrNull { it.id == cardID }
    if (card == null) { LabResolved { vm.setLabArea(LabArea.RESEARCH) }; return }
    var note by remember(card.id) { mutableStateOf("") }
    var policyOpen by remember { mutableStateOf(false) }
    val orderedRuns = card.brief.runs.sortedByDescending { runNumber(it.id) }
    var compareA by remember(card.id, orderedRuns.size) {
        mutableStateOf(orderedRuns.getOrNull(1)?.id ?: orderedRuns.firstOrNull()?.id.orEmpty())
    }
    var compareB by remember(card.id, orderedRuns.size) {
        mutableStateOf(orderedRuns.firstOrNull()?.id.orEmpty())
    }
    Column(Modifier.fillMaxSize()) {
        LabBackBar(card.brief.set.project.uppercase(), card.brief.set.id) { vm.setLabArea(LabArea.RESEARCH) }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item {
                Text(card.brief.set.project, color = labText, fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text("${card.machineName}  /  ${card.brief.set.cwd}", color = labFaint, fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace, modifier = Modifier.padding(top = 5.dp))
                if (card.offline) Text("Read-only mirror · last copied ${ago(card.mirroredAt)}", color = labWaiting,
                    fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
            }
            if (!card.offline) item {
                LabLedgerCard {
                    LabSectionLabel("SET CONTROL", detail = if (vm.labActiveKeyBySet.containsKey(card.id)) "key active" else "access closed")
                    Box {
                        Text("Approval policy  ·  ${card.brief.policy}", color = labText, fontSize = 13.sp,
                            modifier = Modifier.clickable { policyOpen = true }.padding(vertical = 8.dp))
                        DropdownMenu(policyOpen, onDismissRequest = { policyOpen = false }) {
                            listOf("all", "full-only", "none").forEach { policy ->
                                DropdownMenuItem(text = { Text(policy) }, onClick = {
                                    policyOpen = false; vm.setLabPolicy(card, policy)
                                })
                            }
                        }
                    }
                    Row(Modifier.horizontalScroll(rememberScrollState())) {
                        TextButton(onClick = { vm.setLabArchived(card, on = !card.brief.archived) }) {
                            Icon(Icons.Filled.Archive, null); Spacer(Modifier.width(5.dp));
                            Text(if (card.brief.archived) "Restore set" else "Archive set")
                        }
                        if (vm.labActiveKeyBySet.containsKey(card.id)) TextButton(onClick = { vm.revokeLabKey(card) }) {
                            Icon(Icons.Filled.Key, null, tint = labDanger); Spacer(Modifier.width(5.dp)); Text("Revoke key", color = labDanger)
                        }
                    }
                }
            }
            item {
                LabSectionLabel("SET GUIDANCE", detail = "human ground truth")
                val notes = visibleEventNotes(card.brief.setEvents)
                if (notes.isEmpty()) Text("No direct guidance for this set.", color = labFaint, fontSize = 12.sp)
                notes.forEach { event -> LabNoteLine(event.text.orEmpty(), event.time, event.hiddenBy(card.brief.setEvents)) }
                if (!card.offline) {
                    OutlinedTextField(note, { note = it }, label = { Text("Guidance for this experiment set") },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                    Button(onClick = { if (note.isNotBlank()) { vm.postLabSetNote(card, note); note = "" } },
                        enabled = note.isNotBlank() && !vm.labActionBusy, modifier = Modifier.padding(top = 6.dp)) {
                        Text("Publish to set")
                    }
                }
            }
            item { LabSectionLabel("RUN LEDGER", detail = "${card.brief.runs.size} recorded") }
            if (orderedRuns.size > 1) item {
                LabLedgerCard {
                    LabSectionLabel("COMPARE RUNS", detail = "literal recorded evidence")
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        LabRunPicker("A", compareA, orderedRuns, Modifier.weight(1f)) { compareA = it }
                        LabRunPicker("B", compareB, orderedRuns, Modifier.weight(1f)) { compareB = it }
                    }
                    Button(
                        onClick = { vm.openLabCompare(card.id, compareA, compareB) },
                        enabled = compareA.isNotEmpty() && compareB.isNotEmpty() && compareA != compareB,
                        modifier = Modifier.padding(top = 8.dp),
                    ) { Text("Compare recorded runs") }
                }
            }
            if (card.brief.runs.isEmpty()) item { Text("No runs recorded.", color = labFaint, fontSize = 13.sp) }
            items(orderedRuns, key = { it.id }) { run ->
                LabRunRow(run) { vm.openLabRun(card.id, run.id) }
            }
            item { Spacer(Modifier.height(18.dp)) }
        }
    }
}

@Composable
private fun LabRunPicker(
    label: String,
    selected: String,
    runs: List<LabRunSummary>,
    modifier: Modifier = Modifier,
    onSelect: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.fillMaxWidth()) {
            Text("$label  /  $selected", fontFamily = FontFamily.Monospace, maxLines = 1)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            runs.forEach { run ->
                DropdownMenuItem(
                    text = { Text(run.id, fontFamily = FontFamily.Monospace) },
                    onClick = { open = false; onSelect(run.id) },
                )
            }
        }
    }
}

@Composable
private fun LabRunRow(run: LabRunSummary, onClick: () -> Unit) {
    val (label, color) = runStatus(run)
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(labPanel).clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).background(color, CircleShape)); Spacer(Modifier.width(8.dp))
            Text(run.id, color = labText, fontSize = 14.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
            run.tier?.let { Spacer(Modifier.width(7.dp)); LabTag(it.uppercase(), labFaint) }
            run.group?.let { Spacer(Modifier.width(5.dp)); LabTag(it, labFaint) }
            Spacer(Modifier.weight(1f)); Text(label.uppercase(), color = color, fontSize = 10.sp)
        }
        run.latest?.takeIf(String::isNotEmpty)?.let {
            Text(it, color = labDim, fontSize = 13.sp, maxLines = 3, modifier = Modifier.padding(top = 7.dp, start = 16.dp))
        }
    }
}

@Composable
private fun LabRunPage(vm: AppViewModel, cardID: String, runID: String, onOpenTerminal: (Broker, String) -> Unit) {
    val card = vm.labSets.firstOrNull { it.id == cardID }
    val run = card?.brief?.runs?.firstOrNull { it.id == runID }
    if (card == null || run == null) { LabResolved { if (card == null) vm.setLabArea(LabArea.RESEARCH) else vm.openLabSet(card.id) }; return }
    val key = vm.labDetailKey(card, runID)
    val detail = vm.labDetails[key]
    var note by remember(key) { mutableStateOf("") }
    var artifact by remember(key) { mutableStateOf("") }
    LaunchedEffect(key) { vm.loadLabDetail(card, runID) }
    val pending = vm.labPendingRuns.firstOrNull { it.storeID == card.storeID && it.proposal.set == card.brief.set.id && it.proposal.run == runID }
    Column(Modifier.fillMaxSize()) {
        LabBackBar(card.brief.set.project.uppercase(), runID) { vm.openLabSet(card.id) }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(14.dp), verticalArrangement = Arrangement.spacedBy(13.dp)) {
            item {
                val (label, color) = runStatus(run)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(runID, color = labText, fontSize = 26.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
                    Spacer(Modifier.width(9.dp)); LabTag(label.uppercase(), color)
                }
                LabMetaLine(card, run.tier, run.group)
                run.latest?.let { Text(it, color = labDim, fontSize = 15.sp, modifier = Modifier.padding(top = 12.dp)) }
            }
            if (detail == null) item { LinearProgressIndicator(Modifier.fillMaxWidth(), color = labAccent) }
            detail?.let { d ->
                item {
                    LabSectionLabel("RESULT LOG", detail = "append-only")
                    val visible = visibleResultEvents(d.events)
                    if (visible.isEmpty()) Text("No result has been reported yet.", color = labFaint, fontSize = 12.sp)
                    visible.forEach { event ->
                        LabNoteLine(event.text.orEmpty(), event.time, false,
                            onHide = if (!card.offline && event.author == "agent") ({ vm.hideLabSetEvent(card, event.id) }) else null)
                    }
                    if (!card.offline) {
                        OutlinedTextField(note, { note = it }, label = { Text("Add a human note to this run") },
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp))
                        Button(onClick = { if (note.isNotBlank()) { vm.postLabRunNote(card, runID, note); note = "" } },
                            enabled = note.isNotBlank() && !vm.labActionBusy, modifier = Modifier.padding(top = 6.dp)) { Text("Add note") }
                    }
                }
                item { LabReproducibility(d, card, onOpenTerminal) }
                if (d.files.isNotEmpty()) item {
                    LabSectionLabel("STORED ARTIFACTS", detail = "tap to inspect")
                    d.files.forEach { file ->
                        Column(
                            Modifier.fillMaxWidth().clickable {
                                artifact = if (artifact == file.name) "" else file.name
                                if (artifact.isNotEmpty()) vm.loadLabArtifact(card, runID, file.name)
                            }.padding(vertical = 9.dp),
                        ) {
                            Row { Text(file.name, color = labText, fontSize = 12.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f)); Text(bytes(file.size), color = labFaint, fontSize = 10.sp) }
                            if (artifact == file.name) {
                                val text = vm.labDetails[key]?.textByName?.get(file.name)
                                if (text == null) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 7.dp), color = labAccent)
                                else LabCode(text, Modifier.padding(top = 7.dp))
                            }
                        }
                        HorizontalDivider(color = labBorder.copy(alpha = 0.5f))
                    }
                }
                d.end?.wandb.orEmpty().takeIf { it.isNotEmpty() }?.let { refs -> item {
                    val uri = LocalUriHandler.current
                    LabSectionLabel("WEIGHTS & BIASES", detail = "external record")
                    refs.forEach { ref ->
                        val url = if (ref.startsWith("http")) ref else "https://wandb.ai/$ref"
                        Text(ref, color = labAccent, fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                            modifier = Modifier.fillMaxWidth().clickable { uri.openUri(url) }.padding(vertical = 7.dp))
                    }
                } }
            }
            if (pending != null && !card.offline) item {
                var message by remember(pending.id) { mutableStateOf("") }
                LabLedgerCard(accent = labWaiting) {
                    LabSectionLabel("DECISION REQUIRED", detail = pending.proposal.run)
                    OutlinedTextField(message, { message = it }, label = { Text("Optional message") }, modifier = Modifier.fillMaxWidth())
                    Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = { vm.decideLabRun(card, runID, false, message) }) { Text("Reject", color = labDanger) }
                        Button(onClick = { vm.decideLabRun(card, runID, true, message) }, enabled = !vm.labActionBusy) { Text("Approve") }
                    }
                }
            }
            if (!card.offline) item {
                TextButton(onClick = { vm.setLabArchived(card, runID, !run.archived) }) {
                    Icon(Icons.Filled.Archive, null); Spacer(Modifier.width(6.dp)); Text(if (run.archived) "Restore run" else "Archive run")
                }
            }
            item { Spacer(Modifier.height(20.dp)) }
        }
    }
}

@Composable
private fun LabComparePage(vm: AppViewModel, cardID: String, runAID: String, runBID: String) {
    val card = vm.labSets.firstOrNull { it.id == cardID }
    val runA = card?.brief?.runs?.firstOrNull { it.id == runAID }
    val runB = card?.brief?.runs?.firstOrNull { it.id == runBID }
    if (card == null || runA == null || runB == null) {
        LabResolved { if (card == null) vm.setLabArea(LabArea.RESEARCH) else vm.openLabSet(card.id) }
        return
    }
    val keyA = vm.labDetailKey(card, runAID)
    val keyB = vm.labDetailKey(card, runBID)
    val detailA = vm.labDetails[keyA]
    val detailB = vm.labDetails[keyB]
    LaunchedEffect(card.id, runAID, runBID) {
        vm.loadLabDetail(card, runAID)
        vm.loadLabDetail(card, runBID)
    }
    Column(Modifier.fillMaxSize()) {
        LabBackBar("RUN COMPARISON", "$runAID  /  $runBID") { vm.openLabSet(card.id) }
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(14.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            item {
                Text("Recorded difference", color = labText, fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text(
                    "Literal evidence only—no semantic configuration assumptions.",
                    color = labDim, fontSize = 13.sp, modifier = Modifier.padding(top = 6.dp),
                )
                Row(Modifier.fillMaxWidth().padding(top = 15.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    LabCompareRunHead(runA, Modifier.weight(1f))
                    LabCompareRunHead(runB, Modifier.weight(1f))
                }
            }
            if (detailA == null || detailB == null) {
                item { LinearProgressIndicator(Modifier.fillMaxWidth(), color = labAccent) }
            } else {
                val envA = detailA.envelope
                val envB = detailB.envelope
                val endA = detailA.end
                val endB = detailB.end
                item { LabCompareRow("PHASE", runStatus(runA).first, runStatus(runB).first) }
                item { LabCompareRow("LATEST RESULT", latestResult(detailA, runA), latestResult(detailB, runB)) }
                item { LabCompareRow("DURATION", duration(endA?.durationSec), duration(endB?.durationSec)) }
                item { LabCompareRow("EXIT", endA?.exitCode?.toString() ?: exit(runA), endB?.exitCode?.toString() ?: exit(runB)) }
                item { LabCompareRow("COMMAND", envA?.argv.orEmpty().joinToString(" ").ifEmpty { "—" }, envB?.argv.orEmpty().joinToString(" ").ifEmpty { "—" }, true) }
                item { LabCompareRow("CODE", codeState(envA?.snapshot), codeState(envB?.snapshot), true) }
                item { LabCompareRow("PARAMETERS", "${envA?.params?.size ?: 0} captured", "${envB?.params?.size ?: 0} captured") }
                item { LabCompareRow("DECLARED DATA", "${envA?.dataFiles?.size ?: 0} fingerprints", "${envB?.dataFiles?.size ?: 0} fingerprints") }
                item {
                    LabCompareRow(
                        "ENVIRONMENT",
                        environment(envA?.env),
                        environment(envB?.env),
                        true,
                    )
                }
                item {
                    val paramA = firstParameterText(detailA)
                    val paramB = firstParameterText(detailB)
                    LabParameterDelta(paramA, paramB, runAID, runBID)
                }
            }
            item { Spacer(Modifier.height(20.dp)) }
        }
    }
}

@Composable
private fun LabCompareRunHead(run: LabRunSummary, modifier: Modifier = Modifier) {
    val (status, color) = runStatus(run)
    Column(modifier.background(labPanel, RoundedCornerShape(8.dp)).padding(10.dp)) {
        Text(run.id, color = labText, fontSize = 17.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace)
        Text(status.uppercase(), color = color, fontSize = 9.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 3.dp))
    }
}

@Composable
private fun LabCompareRow(label: String, a: String, b: String, mono: Boolean = false) {
    Column(Modifier.fillMaxWidth().background(labPanel, RoundedCornerShape(8.dp)).padding(10.dp)) {
        Text(label, color = labFaint, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)
        Row(Modifier.fillMaxWidth().padding(top = 7.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(a, color = labText, fontSize = 12.sp, fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
                modifier = Modifier.weight(1f))
            Text(b, color = labText, fontSize = 12.sp, fontFamily = if (mono) FontFamily.Monospace else FontFamily.Default,
                modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun LabParameterDelta(a: String?, b: String?, labelA: String, labelB: String) {
    LabLedgerCard {
        LabSectionLabel("PARAMETER DELTA", detail = "exact non-empty lines")
        if (a == null || b == null) {
            Text("Both runs need a captured parameter file for a literal delta.", color = labFaint, fontSize = 12.sp)
            return@LabLedgerCard
        }
        val linesA = a.lines().filter { it.isNotBlank() }
        val linesB = b.lines().filter { it.isNotBlank() }
        val setA = linesA.toSet()
        val setB = linesB.toSet()
        val onlyA = linesA.filter { it !in setB }
        val onlyB = linesB.filter { it !in setA }
        if (onlyA.isEmpty() && onlyB.isEmpty()) {
            Text("Captured parameter lines are identical.", color = labSuccess, fontSize = 12.sp)
        } else {
            Text("ONLY IN $labelA", color = labFaint, fontSize = 9.sp, fontWeight = FontWeight.Bold)
            LabCode(onlyA.joinToString("\n").ifEmpty { "nothing" }, Modifier.padding(top = 5.dp))
            Text("ONLY IN $labelB", color = labFaint, fontSize = 9.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(top = 11.dp))
            LabCode(onlyB.joinToString("\n").ifEmpty { "nothing" }, Modifier.padding(top = 5.dp))
        }
    }
}

private fun firstParameterText(detail: LabRunDetail): String? {
    val ref = detail.envelope?.params?.firstOrNull() ?: return null
    val name = "files/" + ref.path.replace('\\', '/').substringAfterLast('/')
    return detail.textByName[name]
}

private fun latestResult(detail: LabRunDetail, run: LabRunSummary): String =
    detail.events.lastOrNull { it.kind == "result" && !it.text.isNullOrBlank() }?.text
        ?: run.latest.orEmpty().ifEmpty { "—" }

private fun codeState(snapshot: LabSnapshotInfo?): String = when {
    snapshot == null -> "—"
    snapshot.noGit -> "no Git repository"
    else -> snapshot.baseSha.orEmpty().take(10).ifEmpty { "unknown" } +
        if (snapshot.patchBytes > 0) " + ${snapshot.patchBytes} B diff" else " · clean"
}

private fun environment(env: LabEnvFacts?): String =
    listOfNotNull(env?.python, env?.gpus, env?.os, env?.arch).joinToString(" · ").ifEmpty { "—" }

private fun duration(seconds: Int?): String = when {
    seconds == null -> "—"
    seconds < 60 -> "${seconds}s"
    seconds < 3600 -> "${seconds / 60}m ${seconds % 60}s"
    else -> "${seconds / 3600}h ${(seconds % 3600) / 60}m"
}

private fun exit(run: LabRunSummary): String = run.exitCode.takeIf { it >= 0 }?.toString() ?: "—"

@Composable
private fun LabReproducibility(detail: LabRunDetail, card: LabSetCard, onOpenTerminal: (Broker, String) -> Unit) {
    val env = detail.envelope
    val end = detail.end
    LabLedgerCard {
        LabSectionLabel("RECORDED WORLD", detail = "mechanical provenance")
        LabFacts(
            listOf(
                "COMMAND" to env?.argv.orEmpty().joinToString(" ").ifEmpty { "not captured" },
                "WORKING DIR" to env?.cwd.orEmpty().ifEmpty { card.brief.set.cwd },
                "BASE COMMIT" to env?.snapshot?.baseSha.orEmpty().ifEmpty { if (env?.snapshot?.noGit == true) "no repository" else "not captured" },
                "ENVIRONMENT" to listOfNotNull(env?.env?.python, env?.env?.gpus, env?.env?.os, env?.env?.arch).joinToString(" · ").ifEmpty { "not captured" },
                "DURATION" to duration(end?.durationSec),
                "EXIT" to (end?.exitCode?.toString() ?: "not finished"),
            ),
        )
        env?.tmuxSession?.takeIf(String::isNotEmpty)?.let { session ->
            TextButton(onClick = { onOpenTerminal(card.broker, session) }) {
                Icon(Icons.Filled.Terminal, null); Spacer(Modifier.width(6.dp)); Text("Open terminal")
            }
        }
        detail.textByName.entries.filter { it.key.startsWith("files/") }.forEach { (name, text) -> LabEvidence(name, text) }
        detail.textByName["snapshot/diff.patch"]?.let { LabEvidence("CODE DIFF", it) }
        detail.textByName["files/env.txt"]?.let { LabEvidence("ENVIRONMENT FREEZE", it) }
        detail.textByName["log.txt"]?.let { LabEvidence("LOG TAIL", it) }
        if (env?.dataFiles?.isNotEmpty() == true) {
            val drift = end?.drift.orEmpty().toSet()
            Spacer(Modifier.height(10.dp)); Text("DECLARED DATA", color = labFaint, fontSize = 10.sp, fontWeight = FontWeight.Bold)
            env.dataFiles.forEach { ref ->
                val changed = ref.path in drift
                Row(Modifier.fillMaxWidth().padding(top = 7.dp), verticalAlignment = Alignment.Top) {
                    Text("${ref.path}\n${ref.sha256.orEmpty()}", color = labDim, fontSize = 11.sp,
                        fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f))
                    Text(
                        when { changed -> "CHANGED"; end != null -> "UNCHANGED"; else -> "PENDING" },
                        color = when { changed -> labDanger; end != null -> labSuccess; else -> labWaiting },
                        fontSize = 9.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 8.dp),
                    )
                }
            }
        }
    }
}

private enum class GuidanceType { ALL, MACHINE, PROJECT, SET }
private data class GuidanceScope(
    val key: String,
    val type: GuidanceType,
    val label: String,
    val sub: String,
    val storeID: String = "",
    val group: LabNotesGroup? = null,
    val project: String = "",
    val card: LabSetCard? = null,
)
private data class GuidanceReplica(val group: LabNotesGroup, val note: LabHubNote)
private data class GuidanceNote(
    val group: LabNotesGroup?,
    val card: LabSetCard?,
    val note: LabHubNote,
    val replicas: List<GuidanceReplica> = emptyList(),
)

@Composable
private fun LabGuidance(vm: AppViewModel) {
    val scopes = guidanceScopes(vm)
    var selectedKey by remember(vm.labRoute.guidanceKey, scopes.size) {
        mutableStateOf(vm.labRoute.guidanceKey.takeIf { key -> scopes.any { it.key == key } } ?: "all")
    }
    val selected = scopes.firstOrNull { it.key == selectedKey } ?: scopes.first()
    var text by remember(selected.key) { mutableStateOf("") }
    var showHidden by remember { mutableStateOf(false) }
    val notes = guidanceNotes(vm, selected).filter { showHidden || !it.note.hidden }
    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item { LabSectionLabel("AUDIENCES", detail = "exact human channel") }
            item {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    scopes.forEach { scope ->
                        val active = scope.key == selected.key
                        Text(
                            scope.label, color = if (active) labInk else labDim, fontSize = 11.sp,
                            modifier = Modifier.clip(RoundedCornerShape(7.dp))
                                .background(if (active) labAccent else labPanel)
                                .clickable { selectedKey = scope.key }
                                .padding(horizontal = 10.dp, vertical = 7.dp),
                        )
                    }
                }
            }
            item {
                LabLedgerCard(accent = labAccent) {
                    Text(selected.label, color = labText, fontSize = 21.sp, fontWeight = FontWeight.Bold)
                    Text(selected.sub, color = labFaint, fontSize = 11.sp, modifier = Modifier.padding(top = 3.dp))
                    Text(scopeExplanation(selected), color = labDim, fontSize = 13.sp, modifier = Modifier.padding(top = 10.dp))
                    OutlinedTextField(text, { text = it }, label = { Text("Durable guidance") },
                        modifier = Modifier.fillMaxWidth().padding(top = 9.dp))
                    Button(
                        enabled = text.isNotBlank() && !vm.labActionBusy,
                        onClick = {
                            when (selected.type) {
                                GuidanceType.ALL -> vm.postLabEverywhere(text)
                                GuidanceType.MACHINE -> selected.group?.let { vm.postLabScopeNote(it, "machine", "", text) }
                                GuidanceType.PROJECT -> selected.group?.let { vm.postLabScopeNote(it, "project", selected.project, text) }
                                GuidanceType.SET -> selected.card?.let { vm.postLabSetNote(it, text) }
                            }
                            text = ""
                        },
                        modifier = Modifier.padding(top = 7.dp),
                    ) { Text("Publish guidance") }
                }
            }
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    LabSectionLabel("INSTRUCTION LEDGER", Modifier.weight(1f), "${notes.count { !it.note.hidden }} active")
                    Text(if (showHidden) "HIDE ARCHIVED" else "SHOW HIDDEN", color = labFaint, fontSize = 9.sp,
                        modifier = Modifier.clickable { showHidden = !showHidden }.padding(7.dp))
                }
            }
            if (notes.isEmpty()) item { Text("No guidance in this audience.", color = labFaint, fontSize = 13.sp) }
            items(notes, key = { "${it.group?.id ?: it.card?.id}/${it.note.id}" }) { entry ->
                LabGuidanceNote(vm, entry)
            }
            item { Spacer(Modifier.height(18.dp)) }
        }
    }
}

private fun guidanceScopes(vm: AppViewModel): List<GuidanceScope> = buildList {
    add(GuidanceScope("all", GuidanceType.ALL, "Everywhere", "all reachable Lab stores"))
    vm.labNotes.forEach { group ->
        add(GuidanceScope("machine:${group.id}", GuidanceType.MACHINE, group.machineName, "machine", group.storeID, group))
        val projects = vm.labSets.filterNot { it.offline }
            .filter { it.broker.id == group.broker.id || it.machineName == group.machineName }
            .map { it.brief.set.project }.distinct().sorted()
        projects.forEach { project ->
            add(GuidanceScope("project:${group.id}:$project", GuidanceType.PROJECT,
                project, "project · ${group.machineName}", group.storeID, group, project))
        }
    }
    vm.labSets.filterNot { it.offline }.forEach { card ->
        val group = vm.labNotes.firstOrNull { it.storeID == card.storeID && it.broker.id == card.broker.id }
            ?: vm.labNotes.firstOrNull { it.storeID == card.storeID }
        add(GuidanceScope("set:${card.id}", GuidanceType.SET, card.brief.set.id,
            "${card.brief.set.project} · ${shortPath(card.brief.set.cwd)}", card.storeID, group,
            card.brief.set.project, card))
    }
}

private fun guidanceNotes(vm: AppViewModel, scope: GuidanceScope): List<GuidanceNote> {
    val out = mutableListOf<GuidanceNote>()
    val seen = hashSetOf<String>()
    vm.labNotes.forEach { group ->
        group.notes.forEach { note ->
            val sameStore = group.storeID == scope.storeID
            val sameMachine = group.id == scope.group?.id
            val match = when (scope.type) {
                GuidanceType.ALL -> note.scope == "global"
                GuidanceType.MACHINE -> (sameStore && note.scope == "global") || (sameMachine && note.scope == "machine")
                GuidanceType.PROJECT -> (sameStore && note.scope == "global") ||
                    (sameMachine && note.scope == "machine") ||
                    (sameStore && note.scope == "project" && note.project == scope.project)
                GuidanceType.SET -> (sameStore && note.scope == "global") || (sameMachine && note.scope == "machine") ||
                    (sameStore && note.scope == "project" && note.project == scope.project)
            }
            if (!match) return@forEach
            val owner = if (note.scope == "machine") "machine:${group.id}" else "store:${group.storeID}"
            if (seen.add("$owner/${note.id}")) out += GuidanceNote(group, null, note)
        }
    }
    scope.card?.let { card ->
        val hidden = card.brief.setEvents.filter { it.kind == "hide" }.mapNotNull { it.data?.target }.toSet()
        card.brief.setEvents.filter { it.kind == "hnote" || (it.kind == "note" && it.author == "human") }.forEach { event ->
            out += GuidanceNote(null, card, LabHubNote("set", id = event.id, time = event.time,
                author = event.author, text = event.text.orEmpty(), hidden = event.id in hidden))
        }
    }
    return mergeGlobalGuidance(out).sortedByDescending { it.note.time }
}

private fun mergeGlobalGuidance(notes: List<GuidanceNote>): List<GuidanceNote> {
    data class Broadcast(
        val first: GuidanceNote,
        val signature: String,
        val at: Long,
        val stores: MutableSet<String>,
        val replicas: MutableList<GuidanceReplica>,
    )
    val direct = notes.filter { it.note.scope != "global" }.toMutableList()
    val broadcasts = mutableListOf<Broadcast>()
    notes.filter { it.note.scope == "global" }.sortedBy { it.note.time }.forEach { entry ->
        val group = entry.group ?: return@forEach
        val signature = "${entry.note.author}\n${entry.note.text.trim().replace(Regex("\\s+"), " ")}"
        val at = try { Instant.parse(entry.note.time).toEpochMilli() } catch (_: Exception) { Long.MIN_VALUE }
        val candidate = broadcasts.filter {
            it.signature == signature && group.storeID !in it.stores && at != Long.MIN_VALUE &&
                it.at != Long.MIN_VALUE && kotlin.math.abs(at - it.at) <= 120_000
        }.minByOrNull { kotlin.math.abs(at - it.at) }
        if (candidate != null) {
            candidate.stores += group.storeID
            candidate.replicas += GuidanceReplica(group, entry.note)
        } else {
            broadcasts += Broadcast(entry, signature, at, mutableSetOf(group.storeID),
                mutableListOf(GuidanceReplica(group, entry.note)))
        }
    }
    direct += broadcasts.map { broadcast ->
        val latest = broadcast.replicas.maxOf { it.note.time }
        val hidden = broadcast.replicas.all { it.note.hidden }
        broadcast.first.copy(
            note = broadcast.first.note.copy(time = latest, hidden = hidden),
            replicas = broadcast.replicas,
        )
    }
    return direct
}

@Composable
private fun LabGuidanceNote(vm: AppViewModel, entry: GuidanceNote) {
    Row(
        Modifier.fillMaxWidth().background(labPanel, RoundedCornerShape(8.dp)).padding(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(if (entry.note.scope == "global") "EVERYWHERE" else entry.note.scope.uppercase(), color = labAccent, fontSize = 9.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.width(62.dp))
        Column(Modifier.weight(1f)) {
            Text(entry.note.text, color = if (entry.note.hidden) labFaint else labText, fontSize = 13.sp)
            val origin = entry.replicas.takeIf { it.isNotEmpty() }
                ?.let { "${it.size} store${if (it.size == 1) "" else "s"} · " }.orEmpty()
            Text(origin + ago(entry.note.time), color = labFaint, fontSize = 10.sp, modifier = Modifier.padding(top = 4.dp))
        }
        if (!entry.note.hidden) Text(if (entry.replicas.size > 1) "HIDE ALL" else "HIDE", color = labFaint, fontSize = 9.sp,
            modifier = Modifier.clickable {
                if (entry.card != null) vm.hideLabSetEvent(entry.card, entry.note.id)
                else if (entry.replicas.isNotEmpty()) vm.hideLabScopeNotes(
                    entry.replicas.filterNot { it.note.hidden }.map { it.group to it.note },
                )
                else if (entry.group != null) vm.hideLabScopeNote(entry.group, entry.note)
            }.padding(6.dp))
    }
}

private fun scopeExplanation(scope: GuidanceScope): String = when (scope.type) {
    GuidanceType.ALL -> "One network instruction is replicated to each reachable store and shown here once. Every agent brief receives its store's copy."
    GuidanceType.MACHINE -> "Every approved agent on ${scope.label} receives this, regardless of project."
    GuidanceType.PROJECT -> "Agents working on ${scope.project} in this shared store receive it."
    GuidanceType.SET -> "Only the agent holding this experiment set receives it, plus inherited guidance above."
}

@Composable
private fun LabBackBar(kicker: String, id: String, onBack: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(labSurface).clickable(onClick = onBack)
            .padding(horizontal = 8.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = labDim)
        Spacer(Modifier.width(7.dp))
        Column { Text(kicker, color = labFaint, fontSize = 9.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp); Text(id, color = labText, fontSize = 13.sp, fontFamily = FontFamily.Monospace) }
    }
    HorizontalDivider(color = labBorder)
}

@Composable
private fun LabDecisionDock(busy: Boolean, rejectLabel: String, onReject: () -> Unit, onApprove: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(labSurface).border(1.dp, labBorder).padding(10.dp),
        horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = labAccent)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onReject, enabled = !busy) { Text(rejectLabel, color = labDanger) }
        Spacer(Modifier.width(6.dp))
        Button(onClick = onApprove, enabled = !busy,
            colors = ButtonDefaults.buttonColors(containerColor = labSuccess, contentColor = labInk)) { Text("Approve") }
    }
}

@Composable
private fun LabLedgerCard(accent: Color = labBorder, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    Column(
        Modifier.fillMaxWidth().background(labPanel, shape).border(1.dp, accent.copy(alpha = 0.55f), shape)
            .padding(12.dp), content = content,
    )
}

@Composable
private fun LabFacts(facts: List<Pair<String, String>>) {
    Column {
        facts.forEach { (label, value) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.Top) {
                Text(label, color = labFaint, fontSize = 9.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = 0.7.sp, modifier = Modifier.width(92.dp))
                SelectionContainer { Text(value, color = labText, fontSize = 12.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.weight(1f)) }
            }
            HorizontalDivider(color = labBorder.copy(alpha = 0.38f))
        }
    }
}

@Composable
private fun LabSectionLabel(title: String, modifier: Modifier = Modifier, detail: String = "") {
    Row(modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = labText, fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp)
        if (detail.isNotEmpty()) { Spacer(Modifier.width(8.dp)); Text(detail, color = labFaint, fontSize = 10.sp) }
    }
}

@Composable
private fun LabEvidence(title: String, text: String) {
    Spacer(Modifier.height(12.dp)); Text(title.uppercase(), color = labFaint, fontSize = 9.sp, fontWeight = FontWeight.Bold)
    LabCode(text, Modifier.padding(top = 5.dp))
}

@Composable
private fun LabCode(text: String, modifier: Modifier = Modifier) {
    SelectionContainer {
        Text(text, color = labDim, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
            modifier = modifier.fillMaxWidth().heightIn(max = 360.dp).verticalScroll(rememberScrollState())
                .background(labInk, RoundedCornerShape(7.dp)).border(1.dp, labBorder, RoundedCornerShape(7.dp)).padding(10.dp))
    }
}

@Composable
private fun LabTag(text: String, color: Color) {
    Text(text, color = color, fontSize = 9.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.background(color.copy(alpha = 0.12f), RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
}

@Composable
private fun LabMetaLine(card: LabSetCard, tier: String?, group: String?) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(top = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("${card.brief.set.project}  /  ${card.machineName}  /  ${card.brief.set.id}", color = labFaint,
            fontSize = 10.sp, fontFamily = FontFamily.Monospace)
        tier?.let { Spacer(Modifier.width(7.dp)); LabTag(it, labFaint) }
        group?.let { Spacer(Modifier.width(5.dp)); LabTag(it, labFaint) }
    }
}

@Composable
private fun LabNoteLine(text: String, time: String, hidden: Boolean, onHide: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.Top) {
        Text(ago(time), color = labFaint, fontSize = 9.sp, modifier = Modifier.width(40.dp))
        Text(text, color = if (hidden) labFaint else labDim, fontSize = 12.sp, modifier = Modifier.weight(1f))
        if (onHide != null) Text("HIDE", color = labFaint, fontSize = 9.sp, modifier = Modifier.clickable(onClick = onHide).padding(4.dp))
    }
    HorizontalDivider(color = labBorder.copy(alpha = 0.45f))
}

@Composable
private fun LabEmpty(title: String, copy: String) {
    Box(Modifier.fillMaxSize().padding(28.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.size(42.dp).border(1.dp, labBorder, CircleShape), contentAlignment = Alignment.Center) {
                Text("·", color = labAccent, fontSize = 28.sp)
            }
            Text(title, color = labText, fontSize = 19.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 13.dp))
            Text(copy, color = labDim, fontSize = 13.sp, modifier = Modifier.padding(top = 7.dp))
        }
    }
}

@Composable private fun LabCentered(text: String) = Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text(text, color = labDim) }

@Composable
private fun LabResolved(onBack: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.Check, null, tint = labSuccess, modifier = Modifier.size(30.dp))
            Text("This decision is no longer pending.", color = labText, modifier = Modifier.padding(top = 8.dp))
            TextButton(onClick = onBack) { Text("Back to queue") }
        }
    }
}

@Composable
private fun runStatus(run: LabRunSummary): Pair<String, Color> {
    val s = run.status.lowercase()
    return when {
        run.archived -> "archived" to labFaint
        "awaiting approval" in s || s.startsWith("proposed") -> "needs" to labWaiting
        s.startsWith("approved") -> "approved" to labAccent
        s.startsWith("running") -> "running" to labRunning
        s.startsWith("failed") -> "failed" to labDanger
        s.startsWith("denied") -> "rejected" to labDanger
        s.startsWith("done") -> "finished" to labSuccess
        else -> "recorded" to labFaint
    }
}

private fun visibleResultEvents(events: List<LabEvent>): List<LabEvent> {
    val hidden = events.filter { it.kind == "hide" }.mapNotNull { it.data?.target }.toSet()
    return events.filter { it.kind in setOf("result", "note", "hnote") && it.id !in hidden }
}

private fun visibleEventNotes(events: List<LabEvent>): List<LabEvent> =
    events.filter { it.kind == "hnote" || (it.kind == "note" && it.author == "human") }

private fun LabEvent.hiddenBy(events: List<LabEvent>): Boolean =
    events.any { it.kind == "hide" && it.data?.target == id }

private fun runNumber(id: String) = id.dropWhile { !it.isDigit() }.toIntOrNull() ?: 0
private fun shortPath(path: String) = if (path.length <= 34) path else "…/" + path.replace('\\', '/').substringAfterLast('/')
private fun bytes(n: Long) = when { n < 1024 -> "$n B"; n < 1024 * 1024 -> "${n / 1024} KB"; else -> String.format(Locale.US, "%.1f MB", n / 1048576.0) }
private fun ago(iso: String): String = try {
    val d = Duration.between(Instant.parse(iso), Instant.now()).seconds.coerceAtLeast(0)
    when { d < 60 -> "now"; d < 3600 -> "${d / 60}m"; d < 86400 -> "${d / 3600}h"; else -> "${d / 86400}d" }
} catch (_: Exception) { iso }
