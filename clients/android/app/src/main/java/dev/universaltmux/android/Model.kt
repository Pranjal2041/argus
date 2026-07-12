package dev.universaltmux.android

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** App state: the saved brokers, their sessions, and the current selection. */
class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("ut", 0)

    val brokers = mutableStateListOf<Broker>()
    private val brokerSources = mutableMapOf<String, BrokerSource>()
    private val discoveryMisses = mutableMapOf<String, Int>()
    private var discoveryInFlight = false
    private var discoveryPruneRequested = false
    val sessions = mutableStateMapOf<String, List<SessionInfo>>()
    /** Sessions whose agent finished a turn while you weren't viewing them → an ORANGE
     *  "done, unseen" dot until you open the pane. Key = "<brokerId> <name>". */
    val unseen = mutableStateListOf<String>()
    private val prevState = mutableMapOf<String, String>()
    private fun unseenKey(b: Broker, name: String) = "${b.id} $name"

    /** True if this pane is in the orange "done, unseen" state. The UI MUST use this
     *  rather than building the key itself, so the lookup key can never drift from the
     *  one stored in [unseen] (a past separator mismatch silently broke the orange dot). */
    fun isUnseen(b: Broker, name: String): Boolean = unseen.contains(unseenKey(b, name))

    private val _selected = mutableStateOf<Pair<Broker, String>?>(null)
    var selected: Pair<Broker, String>?
        get() = _selected.value
        set(value) {
            _selected.value = value
            if (value != null) {
                val k = unseenKey(value.first, value.second)
                unseen.remove(k)                  // visiting clears orange
                if (k !in acknowledged) acknowledged.add(k) // viewing a prompt acknowledges it
                AttentionNotifier.clear(getApplication(), value.first, value.second)
                recomputeAttention()
            }
        }
    var busy by mutableStateOf(false)
    var lastError by mutableStateOf<String?>(null)
    var authKey by mutableStateOf(prefs.getString("authkey", "") ?: "")
        private set
    var engineStatus by mutableStateOf("off")

    /** Selected color theme (default: Argus = exact current look). Persisted; reading
     *  `theme` in a composable recomposes the UI when it changes. */
    var themeId by mutableStateOf(prefs.getString("themeId", "argus") ?: "argus")
        private set
    val theme: ThemePalette get() = ThemePalette.byId(themeId)
    fun selectTheme(id: String) {
        if (id == themeId) return
        themeId = id
        prefs.edit().putString("themeId", id).apply()
    }

    /** Whether agent-spawned (`ut spawn`) sessions show in the list. They're
     *  background jobs — hidden by default, revealed by the settings toggle.
     *  Persisted; flipping it re-filters the list and the attention inbox. */
    private var _showAgent by mutableStateOf(prefs.getBoolean("showAgent", false))
    var showAgentSessions: Boolean
        get() = _showAgent
        set(v) {
            _showAgent = v
            prefs.edit().putBoolean("showAgent", v).apply()
            recomputeAttention()
        }

    /** Reveal user-hidden sessions (so they can be restored). Transient toggle. */
    var showHidden by mutableStateOf(false)

    /** Hide a session (broker-owned → syncs across devices). Optimistic refresh. */
    fun setHidden(b: Broker, name: String, hidden: Boolean) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { Net.setHidden(b, name, hidden) }
            refresh(b)
        }
    }

    /** Sessions for a broker as shown in the UI: agent sessions filtered out unless
     *  [showAgentSessions] is on, and user-hidden ones unless [showHidden] is on. The
     *  list and attention surfaces both use this. */
    fun visibleSessions(b: Broker): List<SessionInfo> =
        (sessions[b.id] ?: emptyList()).filter { (showAgentSessions || !it.agent) && (showHidden || !it.hidden) }

    // --- W&B run views (detected client-side off the output stream, like the Mac) ----
    val wandbRuns = mutableStateMapOf<String, List<WandbRun>>()    // "<brokerId>/<name>" -> runs (first-seen order)
    val wandbShown = mutableStateListOf<String>()                  // session keys currently showing the webview
    private val wandbCurrent = mutableStateMapOf<String, String>() // session key -> chosen runId
    private val wandbTTL = 7L * 24 * 3600 * 1000

    fun wandbKey(b: Broker, name: String) = "${b.id}/$name"
    fun wandbFor(b: Broker, name: String): List<WandbRun> = wandbRuns[wandbKey(b, name)] ?: emptyList()
    fun hasWandb(b: Broker, name: String) = wandbFor(b, name).isNotEmpty()
    fun isWandbShown(b: Broker, name: String) = wandbShown.contains(wandbKey(b, name))
    fun currentWandbRun(b: Broker, name: String): WandbRun? {
        val runs = wandbFor(b, name); if (runs.isEmpty()) return null
        return runs.firstOrNull { it.runId == wandbCurrent[wandbKey(b, name)] } ?: runs.last()
    }
    fun setWandbCurrent(b: Broker, name: String, run: WandbRun) { wandbCurrent[wandbKey(b, name)] = run.runId }
    fun toggleWandb(b: Broker, name: String) {
        val key = wandbKey(b, name)
        if (wandbShown.contains(key)) wandbShown.remove(key) else if (hasWandb(b, name)) wandbShown.add(key)
    }
    fun hideWandb(b: Broker, name: String) { wandbShown.remove(wandbKey(b, name)) }

    /** Union-merge detected runs into the store (never replace): new ids appended, a bare-id
     *  label upgraded to a real name once captured, original discoveredAt preserved. */
    fun mergeWandb(key: String, found: List<WandbRun>) {
        if (found.isEmpty()) return
        val now = System.currentTimeMillis()
        val byId = LinkedHashMap<String, WandbRun>()
        wandbRuns[key]?.forEach { byId[it.runId] = it }
        var changed = false
        for (r in found) {
            val prev = byId[r.runId]
            if (prev == null) { r.discoveredAt = now; byId[r.runId] = r; changed = true } else {
                val label = if (prev.label != prev.runId) prev.label else r.label
                if (label != prev.label || r.url != prev.url) {
                    byId[r.runId] = WandbRun(r.url, r.runId, label).also { it.discoveredAt = prev.discoveredAt }
                    changed = true
                }
            }
        }
        if (changed) { wandbRuns[key] = byId.values.toList(); saveWandb() }
    }

    private fun saveWandb() {
        val root = JSONObject()
        wandbRuns.forEach { (key, runs) ->
            val arr = JSONArray()
            runs.forEach { arr.put(JSONObject().put("url", it.url).put("runId", it.runId).put("label", it.label).put("discoveredAt", it.discoveredAt)) }
            root.put(key, arr)
        }
        prefs.edit().putString("ut.wandbRuns.v1", root.toString()).apply()
    }
    private fun loadWandb() {
        val s = prefs.getString("ut.wandbRuns.v1", null) ?: return
        val now = System.currentTimeMillis()
        runCatching {
            val root = JSONObject(s)
            for (key in root.keys()) {
                val arr = root.getJSONArray(key)
                val list = (0 until arr.length()).mapNotNull { i ->
                    val o = arr.getJSONObject(i)
                    val da = o.optLong("discoveredAt", now)
                    if (now - da > wandbTTL) null
                    else WandbRun(o.getString("url"), o.getString("runId"), o.getString("label")).also { it.discoveredAt = da }
                }
                if (list.isNotEmpty()) wandbRuns[key] = list
            }
        }
    }

    // Synced user-global data (Workflows + Todo Maps). Declared BEFORE init so they are
    // initialized when init's loadUserData() touches them (Kotlin runs property
    // initializers and init blocks top-to-bottom).
    val workflows = mutableStateListOf<Workflow>()
    val todoBoards = mutableStateListOf<TodoBoard>()
    val notes = mutableStateListOf<Note>()
    private var workflowsTs = 0L
    private var todosTs = 0L
    private var notesTs = 0L

    // --- Argus Lab ----------------------------------------------------------
    // Store-owned records are reduced through LabAggregator before reaching
    // these observable lists, so every Babel NFS store appears exactly once.
    val labSets = mutableStateListOf<LabSetCard>()
    val labPendingKeys = mutableStateListOf<LabPendingKey>()
    val labPendingRuns = mutableStateListOf<LabPendingRun>()
    val labNotes = mutableStateListOf<LabNotesGroup>()
    val labAttention = mutableStateListOf<LabAttentionItem>()
    val labActiveKeyBySet = mutableStateMapOf<String, String>()
    val labDetails = mutableStateMapOf<String, LabRunDetail>()
    val labDetailLoading = mutableStateListOf<String>()
    var labRoute by mutableStateOf(LabRoute())
    var labRefreshing by mutableStateOf(false)
        private set
    var labActionBusy by mutableStateOf(false)
        private set
    var labLoaded by mutableStateOf(false)
        private set
    var labError by mutableStateOf<String?>(null)
        private set
    var requestedScreen by mutableStateOf<Int?>(null)
        private set
    private var labRefreshInFlight = false
    private var labGeneration = 0
    private val labNotified = (prefs.getStringSet("ut.lab.notified.v1", emptySet()) ?: emptySet()).toMutableSet()

    init {
        loadBrokers()
        loadWandb()
        loadUserData()
        refreshAll()
        refreshLab()
        if (authKey.isNotEmpty()) joinTailnet(authKey) // auto-join + auto-discover on startup
    }

    /** Join the tailnet with the shared auth key, then auto-discover brokers (no manual hostnames). */
    fun joinTailnet(key: String) {
        val k = key.trim()
        if (k.isEmpty()) return
        prefs.edit().putString("authkey", k).apply()
        authKey = k
        viewModelScope.launch {
            engineStatus = "joining…"
            val ok = withContext(Dispatchers.IO) { TsnetCore.start(getApplication<Application>(), k) }
            engineStatus = TsnetCore.status
            if (ok) discoverViaTailnet()
        }
    }

    private fun discoverViaTailnet(pruneMissing: Boolean = false) {
        discoveryPruneRequested = discoveryPruneRequested || pruneMissing
        if (discoveryInFlight) return
        discoveryInFlight = true
        viewModelScope.launch {
            try {
                val answer = withContext(Dispatchers.IO) { TsnetCore.discover() }
                val pruneNow = discoveryPruneRequested
                discoveryPruneRequested = false
                val beforeSources = brokerSources.toMap()
                val result = BrokerDiscoveryPolicy.reconcile(
                    current = brokers.toList(),
                    discovered = answer.brokers,
                    sources = beforeSources,
                    misses = discoveryMisses,
                    authoritative = answer.authoritative,
                    pruneNow = pruneNow,
                )
                result.removed.forEach(::forgetBrokerState)
                val listChanged = result.brokers != brokers.toList()
                brokerSources.clear(); brokerSources.putAll(result.sources)
                discoveryMisses.clear(); discoveryMisses.putAll(result.misses)
                if (listChanged) {
                    brokers.clear(); brokers.addAll(result.brokers)
                    saveBrokers()
                } else if (beforeSources != result.sources) {
                    saveBrokers()
                }
                answer.brokers.forEach { discovered ->
                    result.brokers.firstOrNull {
                        BrokerDiscoveryPolicy.key(it.host) == BrokerDiscoveryPolicy.key(discovered.host)
                    }?.let(::refresh)
                }
                if (result.removed.isNotEmpty()) {
                    recomputeAttention()
                    labGeneration++ // invalidate any response built from the old fleet
                    refreshLab()
                }
            } finally {
                discoveryInFlight = false
                // A manual refresh arriving during a sweep must not be lost.
                if (discoveryPruneRequested) discoverViaTailnet()
            }
        }
    }

    private fun loadBrokers() {
        val arr = JSONArray(prefs.getString("brokers", "[]") ?: "[]")
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val broker = Broker(o.getString("host"), o.getString("scheme"), o.optString("name", o.getString("host")), o.optString("os", ""))
            brokers.add(broker)
            val source = when (o.optString("source")) {
                "manual" -> BrokerSource.MANUAL
                "discovered" -> BrokerSource.DISCOVERED
                else -> BrokerDiscoveryPolicy.legacySource(broker.host)
            }
            brokerSources[BrokerDiscoveryPolicy.key(broker.host)] = source
        }
    }

    private fun saveBrokers() {
        val arr = JSONArray()
        brokers.forEach {
            val source = brokerSources[BrokerDiscoveryPolicy.key(it.host)] ?: BrokerSource.DISCOVERED
            arr.put(JSONObject().put("host", it.host).put("scheme", it.scheme).put("name", it.name)
                .put("os", it.os).put("source", if (source == BrokerSource.MANUAL) "manual" else "discovered"))
        }
        prefs.edit().putString("brokers", arr.toString()).apply()
    }

    fun addBroker(hostInput: String) {
        val host = hostInput.trim()
        if (host.isEmpty()) return
        viewModelScope.launch {
            busy = true; lastError = null
            val probed = withContext(Dispatchers.IO) { Net.probe(host) }
            busy = false
            if (probed == null) { lastError = "No broker at $host:8722"; return@launch }
            val brokerKey = BrokerDiscoveryPolicy.key(probed.host)
            brokerSources[brokerKey] = BrokerSource.MANUAL
            discoveryMisses.remove(brokerKey)
            val existing = brokers.indexOfFirst { BrokerDiscoveryPolicy.key(it.host) == brokerKey }
            if (existing >= 0) brokers[existing] = probed else brokers.add(probed)
            saveBrokers()
            refresh(probed)
        }
    }

    fun removeBroker(b: Broker) {
        forgetBrokerState(b)
        brokers.removeAll { it.id == b.id }
        val brokerKey = BrokerDiscoveryPolicy.key(b.host)
        brokerSources.remove(brokerKey)
        discoveryMisses.remove(brokerKey)
        recomputeAttention()
        labGeneration++
        refreshLab()
        saveBrokers()
    }

    fun refreshAll(pruneMissing: Boolean = false) {
        brokers.toList().forEach { refresh(it) }
        if (TsnetCore.isUp) discoverViaTailnet(pruneMissing)
    }

    private fun forgetBrokerState(b: Broker) {
        sessions[b.id].orEmpty().forEach { AttentionNotifier.clear(getApplication(), b, it.name) }
        sessions.remove(b.id)
        if (selected?.first?.id == b.id) selected = null
        val sessionPrefix = "${b.id} "
        unseen.removeAll { it.startsWith(sessionPrefix) }
        acknowledged.removeAll { it.startsWith(sessionPrefix) }
        prevState.keys.removeAll { it.startsWith(sessionPrefix) }
        val ccPrefix = "${b.id}/"
        ccStatus.keys.filter { it.startsWith(ccPrefix) }.forEach { ccStatus.remove(it) }
        pendingOverride.keys.removeAll { it.startsWith(ccPrefix) }
        val backlogChanged = backlog.removeAll { it.startsWith(sessionPrefix) }
        if (backlogChanged) prefs.edit().putString("backlog", backlog.joinToString("\n")).apply()
    }

    /** Refresh sessions for KNOWN brokers without re-running discovery — the cheap
     *  path for the continuous poll loop (discovery is comparatively expensive). */
    fun pollKnown() { brokers.toList().forEach { refresh(it) } }

    fun refresh(b: Broker) {
        viewModelScope.launch {
            val list = withContext(Dispatchers.IO) { Net.sessions(b) }
            if (list != null) {
                // Orange "done, unseen": a turn just finished (working → not-working) on a
                // pane you weren't viewing; cleared when working resumes or you open it.
                // working → WAITING is "needs attention" (amber + notification), not
                // "done unseen" — orange would mask the amber.
                for (s in list) {
                    val k = unseenKey(b, s.name)
                    val prev = prevState[k]
                    val isSel = selected?.first?.id == b.id && selected?.second == s.name
                    if (s.state == "working") unseen.remove(k)
                    else if (prev == "working" && s.state != "waiting" && !isSel && k !in unseen) unseen.add(k)
                    // Attention loop: notify on ENTERING waiting; clear + re-arm on leaving.
                    if (s.state == "waiting" && prev != "waiting") {
                        if (!isSel) AttentionNotifier.post(getApplication(), b, s.name)
                    } else if (s.state != "waiting" && prev == "waiting") {
                        AttentionNotifier.clear(getApplication(), b, s.name)
                        acknowledged.remove(k)
                    }
                    prevState[k] = s.state
                }
                val prefix = "${b.id} "
                val live = list.mapTo(HashSet()) { unseenKey(b, it.name) }
                unseen.removeAll { it.startsWith(prefix) && it !in live }
                acknowledged.removeAll { it.startsWith(prefix) && it !in live }
                sessions[b.id] = list
                recomputeAttention()
            }
        }
    }

    // --- Lab refresh, navigation, and human actions -------------------------

    fun refreshLab() {
        if (labRefreshInFlight) return
        val current = brokers.toList()
        if (current.isEmpty()) {
            labGeneration++
            labAttention.forEach { AttentionNotifier.clearLab(getApplication(), it.targetID) }
            labSets.clear(); labPendingKeys.clear(); labPendingRuns.clear(); labNotes.clear()
            labAttention.clear(); labActiveKeyBySet.clear(); labDetails.clear(); labDetailLoading.clear()
            labRoute = LabRoute()
            labLoaded = true
            labError = null
            return
        }
        labRefreshInFlight = true
        labRefreshing = true
        val generation = ++labGeneration
        viewModelScope.launch {
            try {
                val snapshots = coroutineScope {
                    current.map { broker -> async(Dispatchers.IO) { LabNet.snapshot(broker) } }.awaitAll()
                }
                val mirrorBroker = current.firstOrNull { it.isMac }
                val mirrored = if (mirrorBroker == null) emptyList() else
                    withContext(Dispatchers.IO) { LabNet.mirror(mirrorBroker) }
                val answered = snapshots.any {
                    it.notes != null || it.briefs.isNotEmpty() || it.keys.isNotEmpty() || it.proposals.isNotEmpty()
                }
                if (!answered) {
                    labError = "Lab brokers are temporarily unreachable. Showing the last complete view."
                    return@launch
                }
                val aggregate = LabAggregator.aggregate(snapshots, mirrored, mirrorBroker)
                if (generation != labGeneration) return@launch
                labSets.clear(); labSets.addAll(aggregate.sets)
                labPendingKeys.clear(); labPendingKeys.addAll(aggregate.pendingKeys)
                labPendingRuns.clear(); labPendingRuns.addAll(aggregate.pendingRuns)
                labNotes.clear(); labNotes.addAll(aggregate.notes)
                labActiveKeyBySet.clear(); labActiveKeyBySet.putAll(aggregate.activeKeyBySet)
                labAttention.clear(); labAttention.addAll(aggregate.attention)
                val liveTargets = aggregate.attention.mapTo(hashSetOf()) { it.targetID }
                // Notifications survive process death. Clear every persisted request
                // that is no longer live, not only requests seen by this process.
                labNotified.filter { it !in liveTargets }.forEach {
                    AttentionNotifier.clearLab(getApplication(), it)
                }
                var changed = false
                aggregate.attention.filter { it.targetID !in labNotified }.forEach { item ->
                    AttentionNotifier.postLab(getApplication(), item)
                    labNotified += item.targetID
                    changed = true
                }
                if (changed) {
                    val trimmed = labNotified.toList().takeLast(1000).toSet()
                    labNotified.clear(); labNotified.addAll(trimmed)
                    prefs.edit().putStringSet("ut.lab.notified.v1", trimmed).apply()
                }
                labLoaded = true
                labError = null
                refreshVisibleLabDetails()
            } finally {
                labRefreshInFlight = false
                labRefreshing = false
            }
        }
    }

    fun requestLab(area: LabArea = LabArea.INBOX) {
        labRoute = LabRoute(area = area)
        requestedScreen = SCREEN_LAB
        refreshLab()
    }

    fun openLabAttention(kind: LabAttentionKind, targetID: String) {
        labRoute = LabRoute(area = LabArea.INBOX, attentionKind = kind, targetID = targetID)
        requestedScreen = SCREEN_LAB
        refreshLab()
    }

    fun openLabSet(cardID: String) {
        labRoute = LabRoute(area = LabArea.RESEARCH, cardID = cardID)
        requestedScreen = SCREEN_LAB
    }

    fun openLabRun(cardID: String, runID: String) {
        labRoute = LabRoute(area = LabArea.RESEARCH, cardID = cardID, runID = runID)
        requestedScreen = SCREEN_LAB
        labSets.firstOrNull { it.id == cardID }?.let { loadLabDetail(it, runID) }
    }

    fun openLabCompare(cardID: String, runA: String, runB: String) {
        if (runA == runB) return
        labRoute = LabRoute(
            area = LabArea.RESEARCH,
            cardID = cardID,
            compareRunA = runA,
            compareRunB = runB,
        )
        requestedScreen = SCREEN_LAB
        labSets.firstOrNull { it.id == cardID }?.let { card ->
            loadLabDetail(card, runA)
            loadLabDetail(card, runB)
        }
    }

    fun openLabGuidance(key: String = "all") {
        labRoute = LabRoute(area = LabArea.GUIDANCE, guidanceKey = key)
        requestedScreen = SCREEN_LAB
    }

    fun setLabArea(area: LabArea) {
        labRoute = LabRoute(area = area)
    }

    fun consumeScreenRequest() { requestedScreen = null }
    fun clearLabError() { labError = null }

    fun labDetailKey(card: LabSetCard, run: String) = "${card.id}/$run"

    fun loadLabDetail(card: LabSetCard, run: String, force: Boolean = false) {
        val key = labDetailKey(card, run)
        if (key in labDetailLoading || (!force && labDetails.containsKey(key))) return
        labDetailLoading += key
        viewModelScope.launch {
            val detail = withContext(Dispatchers.IO) { LabNet.runDetail(card, run) }
            labDetails[key] = detail
            labDetailLoading.remove(key)
        }
    }

    fun loadLabArtifact(card: LabSetCard, run: String, name: String) {
        val key = labDetailKey(card, run)
        if (labDetails[key]?.textByName?.containsKey(name) == true || key in labDetailLoading) return
        labDetailLoading += key
        viewModelScope.launch {
            val text = withContext(Dispatchers.IO) { LabNet.artifact(card, run, name) }
            if (text != null) {
                val current = labDetails[key] ?: LabRunDetail()
                labDetails[key] = current.copy(textByName = current.textByName + (name to text))
            }
            labDetailLoading.remove(key)
        }
    }

    private fun refreshVisibleLabDetails(force: Boolean = false) {
        val route = labRoute
        val card = (labSets.firstOrNull { it.id == route.cardID }
            ?: if (route.attentionKind == LabAttentionKind.PROPOSAL) {
                labPendingRuns.firstOrNull { it.id == route.targetID }?.let { pending ->
                    labSets.firstOrNull {
                        it.storeID == pending.storeID && it.brief.set.id == pending.proposal.set
                    }
                }
            } else null) ?: return
        val runs = buildSet {
            if (route.runID.isNotEmpty()) add(route.runID)
            if (route.compareRunA.isNotEmpty()) add(route.compareRunA)
            if (route.compareRunB.isNotEmpty()) add(route.compareRunB)
            if (route.attentionKind == LabAttentionKind.PROPOSAL) {
                labPendingRuns.firstOrNull { it.id == route.targetID }?.proposal?.run?.let(::add)
            }
        }
        runs.forEach { runID ->
            val status = card.brief.runs.firstOrNull { it.id == runID }?.status.orEmpty().lowercase()
            val live = status.startsWith("running") || status.startsWith("proposed") || status.startsWith("approved")
            if (force || live) loadLabDetail(card, runID, force = true)
        }
    }

    private fun labAction(operation: suspend () -> Boolean) {
        if (labActionBusy) return
        labActionBusy = true
        labError = null
        viewModelScope.launch {
            val ok = operation()
            labActionBusy = false
            if (ok) {
                refreshLab()
                refreshVisibleLabDetails(force = true)
            } else labError = "The Lab broker did not accept this change."
        }
    }

    fun decideLabKey(item: LabPendingKey, approve: Boolean, project: String, note: String = "") =
        labAction { withContext(Dispatchers.IO) { LabNet.decideKey(item, approve, project, note) } }

    fun decideLabRun(card: LabSetCard, run: String, approve: Boolean, note: String) =
        labAction { withContext(Dispatchers.IO) { LabNet.decideRun(card, run, approve, note) } }

    fun setLabPolicy(card: LabSetCard, policy: String) =
        labAction { withContext(Dispatchers.IO) { LabNet.policy(card, policy) } }

    fun setLabArchived(card: LabSetCard, run: String = "", on: Boolean) =
        labAction { withContext(Dispatchers.IO) { LabNet.archive(card, run, on) } }

    fun revokeLabKey(card: LabSetCard) {
        val key = labActiveKeyBySet[card.id] ?: return
        labAction { withContext(Dispatchers.IO) { LabNet.revoke(card, key) } }
    }

    fun postLabSetNote(card: LabSetCard, text: String) = labAction {
        withContext(Dispatchers.IO) {
            LabNet.postNote(card.broker, "set", text, set = card.brief.set.id)
        }
    }

    fun postLabRunNote(card: LabSetCard, run: String, text: String) = labAction {
        withContext(Dispatchers.IO) {
            LabNet.postNote(card.broker, "run", text, set = card.brief.set.id, run = run)
        }
    }

    fun postLabScopeNote(group: LabNotesGroup, scope: String, project: String, text: String) = labAction {
        withContext(Dispatchers.IO) { LabNet.postNote(group.broker, scope, text, project = project) }
    }

    fun postLabEverywhere(text: String) = labAction {
        withContext(Dispatchers.IO) {
            labNotes.distinctBy { it.storeID }.map {
                LabNet.postNote(it.broker, "global", text)
            }.all { it }
        }
    }

    fun hideLabScopeNote(group: LabNotesGroup, note: LabHubNote) = labAction {
        withContext(Dispatchers.IO) {
            LabNet.hide(group.broker, note.id, scope = note.scope, project = note.project.orEmpty())
        }
    }

    fun hideLabSetEvent(card: LabSetCard, target: String) = labAction {
        withContext(Dispatchers.IO) { LabNet.hide(card.broker, target, set = card.brief.set.id) }
    }

    // --- command center ----------------------------------------------------

    /** AI statuses published by the Mac, read per broker. Key = "<brokerId>/<session>". */
    val ccStatus = mutableStateMapOf<String, AgentCardStatus>()
    private fun ccKey(b: Broker, name: String) = "${b.id}/$name"
    fun ccFor(b: Broker, name: String): AgentCardStatus? = ccStatus[ccKey(b, name)]

    // A status the user set on THIS device, shown optimistically until the Mac reflects
    // it back via /ccstatus (or a 15s timeout) — so the card doesn't flicker to the old
    // label on the next poll before the Mac has processed the override.
    private val pendingOverride = mutableStateMapOf<String, Pair<String, Long>>()

    /** Manually set a card's status from the phone: optimistic locally + relayed to the
     *  Mac (the only generator) via the broker, which applies it and re-publishes. */
    fun setManualStatus(b: Broker, name: String, label: String) {
        val k = ccKey(b, name)
        val cur = ccStatus[k]
        ccStatus[k] = AgentCardStatus(name, label, cur?.summary ?: "", cur?.lookAtThis, System.currentTimeMillis() / 1000.0)
        pendingOverride[k] = label to System.currentTimeMillis()
        viewModelScope.launch { withContext(Dispatchers.IO) { Net.setCCOverride(b, name, label) } }
    }

    /** Pull each broker's /ccstatus and merge (each broker holds only its own sessions). */
    fun refreshCC() {
        brokers.toList().forEach { b ->
            viewModelScope.launch {
                val items = withContext(Dispatchers.IO) { Net.ccStatus(b) }
                val prefix = "${b.id}/"
                val live = HashSet<String>()
                items.forEach { item ->
                    val k = ccKey(b, item.session)
                    val pend = pendingOverride[k]
                    // Keep showing a just-set override until the Mac's published status
                    // matches it (or it ages out) — otherwise the card flickers back.
                    ccStatus[k] = if (pend != null && pend.first != item.label && System.currentTimeMillis() - pend.second < 15_000) {
                        item.copy(label = pend.first)
                    } else {
                        pendingOverride.remove(k)
                        item
                    }
                    live.add(k)
                }
                ccStatus.keys.filter { it.startsWith(prefix) && it !in live }.forEach { ccStatus.remove(it) }
            }
        }
    }

    /** Sessions the user has "ticked" to set aside in the command center. Key = "<id> name". */
    val backlog = mutableStateListOf<String>().also { it.addAll((prefs.getString("backlog", "") ?: "").split("\n").filter(String::isNotEmpty)) }
    private fun blKey(b: Broker, name: String) = "${b.id} $name"
    fun isBacklogged(b: Broker, name: String) = backlog.contains(blKey(b, name))
    fun toggleBacklog(b: Broker, name: String) {
        val k = blKey(b, name)
        if (backlog.contains(k)) backlog.remove(k) else backlog.add(k)
        prefs.edit().putString("backlog", backlog.joinToString("\n")).apply()
    }

    fun rename(b: Broker, from: String, to: String) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { Net.rename(b, from, to) }
            if (selected?.first?.id == b.id && selected?.second == from) selected = b to to
            refresh(b)
        }
    }

    /** Sessions blocked on the user, minus ones already viewed/answered — drives
     *  the pinned "Needs attention" section. A PUSHED observable list (rebuilt by
     *  recomputeAttention on every refresh / ack change), NOT a computed getter:
     *  a getter read transitively through sessions[b.id] inside the LazyColumn
     *  builder did not reliably re-run the builder, so the section never appeared. */
    val attention = mutableStateListOf<Pair<Broker, SessionInfo>>()

    private fun recomputeAttention() {
        val next = brokers.flatMap { b ->
            visibleSessions(b)
                .filter { !it.hidden && it.state == "waiting" && unseenKey(b, it.name) !in acknowledged }
                .map { b to it }
        }
        if (next != attention.toList()) {
            attention.clear()
            attention.addAll(next)
        }
    }

    /** Viewed-or-answered waiting sessions (suppressed from the inbox until the
     *  broker reports them leaving "waiting", which re-arms them). */
    private val acknowledged = mutableStateListOf<String>()

    fun create(b: Broker, name: String, dir: String?) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { Net.control(b, "create", name, dir) }
            selected = b to name
            refresh(b)
        }
    }

    fun kill(b: Broker, name: String) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { Net.control(b, "kill", name, null) }
            if (selected == (b to name)) selected = null
            refresh(b)
        }
    }

    // ===================== Workflows + Todo Maps (synced) =====================
    // User-global data synced through the Mac broker (the sync host): a local copy lives
    // here + in prefs, and reconcile() trades it with the host using last-write-wins.
    // NOTE: the state lists are declared ABOVE init (see top of the class) so they are
    // non-null when init's loadUserData() runs.

    private fun now() = System.currentTimeMillis()
    private fun syncHost(): Broker? = brokers.firstOrNull { it.isMac }

    private fun loadUserData() {
        UserDataJson.parseWorkflows(prefs.getString("ut.workflows.v1", null))?.let { (ts, list) ->
            workflowsTs = ts; workflows.clear(); workflows.addAll(list)
        }
        UserDataJson.parseTodos(prefs.getString("ut.todoBoards.v1", null))?.let { (ts, list) ->
            todosTs = ts; todoBoards.clear(); todoBoards.addAll(list)
        }
        if (todoBoards.none { it.isMisc }) todoBoards.add(TodoBoard(isMisc = true))
        UserDataJson.parseNotes(prefs.getString("ut.notes.v1", null))?.let { (ts, list) ->
            notesTs = ts; notes.clear(); notes.addAll(list)
        }
    }
    private fun saveWorkflowsLocal() {
        prefs.edit().putString("ut.workflows.v1", UserDataJson.workflowsEnvelope(workflowsTs, workflows.toList())).apply()
    }
    private fun saveTodosLocal() {
        prefs.edit().putString("ut.todoBoards.v1", UserDataJson.todosEnvelope(todosTs, todoBoards.toList())).apply()
    }
    private fun touchWorkflows() {
        workflowsTs = now(); saveWorkflowsLocal()
        val h = syncHost() ?: return
        val body = UserDataJson.workflowsEnvelope(workflowsTs, workflows.toList())
        viewModelScope.launch { withContext(Dispatchers.IO) { Net.postUserData(h, "workflows", body) } }
    }
    private fun touchTodos() {
        todosTs = now(); saveTodosLocal()
        val h = syncHost() ?: return
        val body = UserDataJson.todosEnvelope(todosTs, todoBoards.toList())
        viewModelScope.launch { withContext(Dispatchers.IO) { Net.postUserData(h, "todos", body) } }
    }

    fun upsertWorkflow(w: Workflow) {
        val i = workflows.indexOfFirst { it.id == w.id }
        if (i >= 0) workflows[i] = w else workflows.add(w)
        touchWorkflows()
    }
    fun deleteWorkflow(w: Workflow) { workflows.removeAll { it.id == w.id }; touchWorkflows() }

    fun ensureBoard(machine: String, session: String) {
        val m = machine.trim(); val s = session.trim()
        if (s.isEmpty()) return
        if (todoBoards.none { !it.isMisc && it.machine == m && it.session == s }) {
            todoBoards.add(TodoBoard(machine = m, session = s)); touchTodos()
        }
    }
    fun addTodo(boardId: String, text: String) {
        val t = text.trim(); if (t.isEmpty()) return
        val i = todoBoards.indexOfFirst { it.id == boardId }; if (i < 0) return
        val items = todoBoards[i].items.toMutableList(); items.add(TodoItem(text = t))
        todoBoards[i] = todoBoards[i].copy(items = items); touchTodos()
    }
    fun toggleTodo(boardId: String, itemId: String) {
        val i = todoBoards.indexOfFirst { it.id == boardId }; if (i < 0) return
        val items = todoBoards[i].items.map {
            if (it.id == itemId) { val nd = !it.done; it.copy(done = nd, completedAt = if (nd) nowIso() else null) } else it
        }.toMutableList()
        todoBoards[i] = todoBoards[i].copy(items = items); touchTodos()
    }
    fun deleteTodo(boardId: String, itemId: String) {
        val i = todoBoards.indexOfFirst { it.id == boardId }; if (i < 0) return
        val items = todoBoards[i].items.filter { it.id != itemId }.toMutableList()
        todoBoards[i] = todoBoards[i].copy(items = items); touchTodos()
    }
    fun deleteBoard(boardId: String) { todoBoards.removeAll { it.id == boardId && !it.isMisc }; touchTodos() }

    // -- Notes Hub: bump+save on edit; the reconcile pushes (no POST per keystroke) --
    private fun saveNotesLocal() { prefs.edit().putString("ut.notes.v1", UserDataJson.notesEnvelope(notesTs, notes.toList())).apply() }
    private fun touchNotes() { notesTs = now(); saveNotesLocal() }
    fun addNote(): String { val n = Note(); notes.add(n); touchNotes(); return n.id }
    fun updateNoteText(id: String, text: String) {
        val i = notes.indexOfFirst { it.id == id }; if (i < 0) return
        notes[i] = notes[i].copy(text = text, editedAt = nowIso()); touchNotes()
    }
    fun toggleNote(id: String) {
        val i = notes.indexOfFirst { it.id == id }; if (i < 0) return
        notes[i] = notes[i].copy(done = !notes[i].done); touchNotes()
    }
    fun deleteNote(id: String) { notes.removeAll { it.id == id }; touchNotes() }

    // -- machine pattern matching + running a workflow --
    private fun wildcardRegex(p: String): Regex {
        val sb = StringBuilder("^")
        for (c in p) when {
            c == '*' -> sb.append(".*")
            c.isLetterOrDigit() || c == ' ' || c == '_' || c == '-' -> sb.append(c)
            else -> sb.append('\\').append(c)
        }
        sb.append('$')
        return Regex(sb.toString(), RegexOption.IGNORE_CASE)
    }
    fun brokersMatching(pattern: String): List<Broker> {
        val p = pattern.trim()
        if (p.isEmpty()) return emptyList()
        if (p.equals("this mac", true) || p.equals("mac", true) || p.equals("local", true))
            return brokers.filter { it.isMac }
        val rx = wildcardRegex(p)
        return brokers.filter { rx.matches(it.name) }
    }
    private fun cdCommand(folder: String): String =
        if (folder == "~" || folder.startsWith("~/")) "cd $folder"
        else "cd '" + folder.replace("'", "'\\''") + "'"

    fun runWorkflowOn(wf: Workflow, b: Broker) {
        val exists = (sessions[b.id] ?: emptyList()).any { it.name == wf.name }
        if (exists) { selected = b to wf.name; return }
        viewModelScope.launch {
            withContext(Dispatchers.IO) { Net.control(b, "create", wf.name, null) }
            selected = b to wf.name
            refresh(b)
            kotlinx.coroutines.delay(700)
            val lines = mutableListOf<String>()
            val folder = wf.folder.trim()
            if (folder.isNotEmpty()) lines.add(cdCommand(folder))
            lines.addAll(wf.commands.split("\n").map { it.trim() }.filter { it.isNotEmpty() })
            for (line in lines) { withContext(Dispatchers.IO) { Net.send(b, wf.name, line) }; kotlinx.coroutines.delay(250) }
        }
    }

    // -- todo board live detection --
    private fun boardBrokerMatch(b: Broker, board: TodoBoard) =
        b.name == board.machine || (b.isMac && (board.machine.equals("this mac", true) ||
            board.machine.equals("mac", true) || board.machine.equals("local", true)))
    fun liveBrokerFor(board: TodoBoard): Broker? =
        if (board.isMisc) null else brokers.firstOrNull { b ->
            boardBrokerMatch(b, board) && (sessions[b.id] ?: emptyList()).any { it.name == board.session }
        }
    fun isSessionLive(board: TodoBoard) = liveBrokerFor(board) != null

    /** Fill in each broker's os (Mac-detection) by probing /whoami — the discovery engine
     *  may not carry it yet. Runs after discovery + on the poll. */
    fun enrichOs() {
        brokers.toList().forEach { b ->
            if (b.os.isEmpty()) viewModelScope.launch {
                val probed = withContext(Dispatchers.IO) { Net.probe(b.host) }
                if (probed != null && probed.os.isNotEmpty()) {
                    val i = brokers.indexOfFirst { it.host == b.host }
                    if (i >= 0 && brokers[i].os.isEmpty()) { brokers[i] = brokers[i].copy(os = probed.os); saveBrokers() }
                }
            }
        }
    }

    /** Reconcile both keys with the Mac sync host: adopt remote when newer, push local when
     *  newer (or to bootstrap). Runs on the poll loop. */
    /** Flush phone-captured journal events to the Mac broker's inbox. */
    fun flushJournal() {
        val h = syncHost() ?: return
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                val jsonl = JournalOutbox.pendingJSONL() ?: return@withContext
                val n = jsonl.count { it == '\n' }
                if (Net.postJournal(h, jsonl)) JournalOutbox.clearFirst(n)
            }
        }
    }

    fun syncUserData() {
        val h = syncHost() ?: return
        viewModelScope.launch {
            val rawW = withContext(Dispatchers.IO) { Net.getUserData(h, "workflows") }
            val remoteW = UserDataJson.parseWorkflows(rawW); val rwTs = remoteW?.first ?: 0L
            var lw = workflowsTs
            if (lw == 0L && workflows.isNotEmpty()) { lw = now(); workflowsTs = lw; saveWorkflowsLocal() }
            if (remoteW != null && rwTs > lw) {
                workflows.clear(); workflows.addAll(remoteW.second); workflowsTs = rwTs; saveWorkflowsLocal()
            } else if (lw > rwTs) {
                withContext(Dispatchers.IO) { Net.postUserData(h, "workflows", UserDataJson.workflowsEnvelope(lw, workflows.toList())) }
            }

            val rawT = withContext(Dispatchers.IO) { Net.getUserData(h, "todos") }
            val remoteT = UserDataJson.parseTodos(rawT); val rtTs = remoteT?.first ?: 0L
            val hasData = todoBoards.any { !it.isMisc || it.items.isNotEmpty() }
            var lt = todosTs
            if (lt == 0L && hasData) { lt = now(); todosTs = lt; saveTodosLocal() }
            if (remoteT != null && rtTs > lt) {
                val boards = remoteT.second.toMutableList()
                if (boards.none { it.isMisc }) boards.add(TodoBoard(isMisc = true))
                todoBoards.clear(); todoBoards.addAll(boards); todosTs = rtTs; saveTodosLocal()
            } else if (lt > rtTs) {
                withContext(Dispatchers.IO) { Net.postUserData(h, "todos", UserDataJson.todosEnvelope(lt, todoBoards.toList())) }
            }

            val rawN = withContext(Dispatchers.IO) { Net.getUserData(h, "notes") }
            val remoteN = UserDataJson.parseNotes(rawN); val rnTs = remoteN?.first ?: 0L
            var ln = notesTs
            if (ln == 0L && notes.isNotEmpty()) { ln = now(); notesTs = ln; saveNotesLocal() }
            if (remoteN != null && rnTs > ln) {
                notes.clear(); notes.addAll(remoteN.second); notesTs = rnTs; saveNotesLocal()
            } else if (ln > rnTs) {
                withContext(Dispatchers.IO) { Net.postUserData(h, "notes", UserDataJson.notesEnvelope(ln, notes.toList())) }
            }
        }
    }
}
