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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

/** App state: the saved brokers, their sessions, and the current selection. */
class AppViewModel @JvmOverloads constructor(app: Application, startServices: Boolean = true) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("ut", 0)
    val brokerDocuments = BrokerDocumentCache(app, viewModelScope)
    private val workspaceBrowsers = mutableMapOf<String, WorkspaceBrowserSession>()
    val workspaceBlobs = WorkspaceBlobs(app)
    val artifactTransfers by lazy { ArtifactTransfers(app, workspace, workspaceBlobs) }
    fun workspaceBrowser(id: String) = workspaceBrowsers.getOrPut(workspace.workspaceID + "/" + id) { WorkspaceBrowserSession(id) }
    override fun onCleared() { workspaceBrowsers.values.forEach { it.close() }; super.onCleared() }
    val workspace = WorkspaceRepository(object : WorkspacePersistence {
        override fun read(workspaceID: String) = prefs.getString("ut.replica.$workspaceID", null)
        override fun write(workspaceID: String, document: String) {
            check(prefs.edit().putString("ut.replica.$workspaceID", document).commit()) { "Could not persist workspace changes." }
        }
    })
    var workspaceSelectionIssue by mutableStateOf<String?>(null)
        private set
    var terminalVisible = false
    private var workspaceRefreshInFlight = false
    private val fileControllers = mutableMapOf<String, FilesController>()
    fun filesFor(broker: Broker): FilesController = fileControllers.getOrPut(broker.id) {
        FilesController(broker, getApplication<Application>())
    }.also { it.broker = broker }
    fun saveFile(controller: FilesController, file: OpenFile, text: String, complete: (Boolean) -> Unit) {
        viewModelScope.launch { complete(controller.save(file, text)) }
    }

    val brokers = mutableStateListOf<Broker>()
    private val brokerSources = mutableMapOf<String, BrokerSource>()
    private val discoveryMisses = mutableMapOf<String, Int>()
    private val sessionRefreshInFlight = mutableSetOf<String>()
    private val identityRefreshInFlight = mutableSetOf<String>()
    private val identityRefreshedAt = mutableMapOf<String, Long>()
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
    fun isUnseen(b: Broker, name: String): Boolean = unseen.contains(unseenKey(b, name)) &&
        !isSharedRead(b, sessions[b.id].orEmpty().firstOrNull { it.name == name })

    private val _selected = mutableStateOf<Pair<Broker, String>?>(null)
    var selected: Pair<Broker, String>?
        get() = _selected.value
        set(value) {
            _selected.value = value
            if (value != null) {
                val k = unseenKey(value.first, value.second)
                unseen.remove(k)                  // visiting clears orange
                if (k !in acknowledged) acknowledged.add(k) // viewing a prompt acknowledges it
                acknowledgeShared(value.first, value.second)
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
    val planner = mutableStateListOf<PlannerCommitment>()
    private var workflowsTs = 0L
    private var todosTs = 0L
    private var notesTs = 0L
    private var plannerTs = 0L
    private var workflowsDestructive = prefs.getBoolean("ut.workflows.pendingDestructive", false)
    private var todosDestructive = prefs.getBoolean("ut.todos.pendingDestructive", false)
    private var notesDestructive = prefs.getBoolean("ut.notes.pendingDestructive", false)
    val workspaceSyncIssues = mutableStateMapOf<String, String>()
    private val workspaceSyncInflight = mutableSetOf<String>()

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
    var unattendedMode by mutableStateOf(prefs.getBoolean("ut.unattendedMode", false))
        private set
    var unattendedModeUpdating by mutableStateOf(false)
        private set
    var unattendedModeError by mutableStateOf<String?>(null)
        private set
    var requestedScreen by mutableStateOf<Int?>(null)
        private set
    private var labRefreshInFlight = false
    private var labGeneration = 0
    private val labNotified = (prefs.getStringSet("ut.lab.notified.v1", emptySet()) ?: emptySet()).toMutableSet()

    // --- Weekly Progress ---------------------------------------------------
    // The Mac owns projects, generations, files, and Codex. Android keeps only
    // an observable catalog plus disposable reading caches.
    var weeklyProgressCatalog by mutableStateOf(WeeklyProgressCatalog())
        private set
    var weeklyProgressRefreshing by mutableStateOf(false)
        private set
    var weeklyProgressProviderAvailable by mutableStateOf(false)
        private set
    var weeklyProgressActionBusy by mutableStateOf(false)
        private set
    var weeklyProgressError by mutableStateOf<String?>(null)
        private set
    private var weeklyProgressRefreshInFlight = false
    private var weeklyProgressLastRefreshAt = 0L
    private var weeklyProgressHostId = prefs.getString("ut.weeklyProgress.host", null)

    init {
        loadBrokers()
        loadWandb()
        loadUserData()
        prefs.getString("ut.workspace.id", null)?.let { workspace.bind(it) }
        workspace.onChange = {
            brokers.forEach { broker -> sessions[broker.id].orEmpty().filter { isSharedRead(broker, it) }.forEach {
                unseen.remove(unseenKey(broker, it.name))
                AttentionNotifier.clear(getApplication(), broker, it.name)
            } }
            recomputeAttention()
        }
        weeklyProgressCatalog = WeeklyProgressNet.loadCachedCatalog(app) ?: WeeklyProgressCatalog()
        if (startServices) {
            refreshAll()
            refreshLab()
            if (authKey.isNotEmpty()) joinTailnet(authKey) // auto-join + auto-discover on startup
        }
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
            val capabilities = o.optJSONArray("capabilities") ?: JSONArray()
            val broker = Broker(o.getString("host"), o.getString("scheme"), o.optString("name", o.getString("host")), o.optString("os", ""),
                o.optString("brokerID"), o.optString("workspaceID"), o.optBoolean("workspaceEnabled"),
                (0 until capabilities.length()).map { capabilities.getString(it) }.toSet())
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
                .put("os", it.os).put("brokerID", it.brokerID).put("workspaceID", it.workspaceID)
                .put("workspaceEnabled", it.workspaceEnabled).put("capabilities", JSONArray(it.capabilities.toList()))
                .put("source", if (source == BrokerSource.MANUAL) "manual" else "discovered"))
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
        corrections.discardMatching { it.substringAfter('/').startsWith(ccPrefix) }
        val backlogChanged = backlog.removeAll { it.startsWith(sessionPrefix) }
        if (backlogChanged) prefs.edit().putString("backlog", backlog.joinToString("\n")).apply()
    }

    /** Refresh sessions for KNOWN brokers without re-running discovery — the cheap
     *  path for the continuous poll loop (discovery is comparatively expensive). */
    fun pollKnown() { brokers.toList().forEach { refresh(it) } }

    fun refresh(b: Broker) {
        if (!sessionRefreshInFlight.add(b.id)) return
        viewModelScope.launch {
          try {
            val list = withContext(Dispatchers.IO) { Net.sessions(b) }
            if (list != null && brokers.any { it.id == b.id }) {
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
                if (terminalVisible) selected?.takeIf { it.first.id == b.id }?.let { acknowledgeShared(it.first, it.second) }
                recomputeAttention()
            }
          } finally { sessionRefreshInFlight.remove(b.id) }
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
                val remoteUnattended = if (mirrorBroker == null) null else
                    withContext(Dispatchers.IO) { LabNet.unattendedMode(mirrorBroker) }
                val answered = snapshots.any {
                    it.notes != null || it.briefs.isNotEmpty() || it.keys.isNotEmpty() || it.proposals.isNotEmpty()
                }
                if (!answered) {
                    labError = "Lab brokers are temporarily unreachable. Showing the last complete view."
                    return@launch
                }
                val aggregate = LabAggregator.aggregate(snapshots, mirrored, mirrorBroker)
                if (generation != labGeneration) return@launch
                if (!unattendedModeUpdating && remoteUnattended != null) {
                    unattendedMode = remoteUnattended
                    unattendedModeError = null
                    prefs.edit().putBoolean("ut.unattendedMode", remoteUnattended).apply()
                }
                val previousSummaries = labSets.flatMap { card ->
                    card.brief.runs.map { run -> labDetailKey(card, run.id) to labSummaryFingerprint(run) }
                }.toMap()
                val changedDetails = aggregate.sets.flatMap { card ->
                    card.brief.runs.mapNotNull { run ->
                        val key = labDetailKey(card, run.id)
                        key.takeIf { previousSummaries[key]?.let { it != labSummaryFingerprint(run) } == true }
                    }
                }.toSet()
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
                val routeKey = labRoute.runID.takeIf { it.isNotEmpty() }?.let { "${labRoute.cardID}/$it" }
                refreshVisibleLabDetails(force = routeKey != null && routeKey in changedDetails)
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
        labSets.firstOrNull { it.id == cardID }?.let { loadLabDetail(it, runID, force = true) }
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
            loadLabDetail(card, runA, force = true)
            loadLabDetail(card, runB, force = true)
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
    fun requestUsage() { requestedScreen = SCREEN_USAGE }
    var requestedArtifactID by mutableStateOf<String?>(null)
    fun requestArtifacts(id: String? = null) { requestedArtifactID = id?.lowercase(); requestedScreen = SCREEN_ARTIFACTS }
    fun refreshArtifactTransfers() {
        viewModelScope.launch { artifactTransfers.flush(workspaceHost()); if (workspace.pending.isNotEmpty()) refreshWorkspace() }
    }
    fun artifactPanel(broker: Broker? = selected?.first): JSONObject {
        val name = selected?.takeIf { it.first.id == broker?.id }?.second.orEmpty()
        val session = broker?.let { b -> sessions[b.id]?.firstOrNull { it.name == name } }
        return JSONObject().put("machineID", broker?.id ?: "phone").put("machineName", broker?.name ?: "Phone")
            .put("machineHost", broker?.host.orEmpty()).put("sessionName", name)
            .put("sessionLineageID", session?.lineageID).put("stableSessionID", session?.tmuxId).put("folder", session?.path.orEmpty())
    }
    fun snapshotArtifact(broker: Broker, path: String, filename: String) {
        val panel = artifactPanel(broker)
        viewModelScope.launch {
            try {
                val file = withContext(Dispatchers.IO) {
                    val temp = java.io.File.createTempFile("artifact-snapshot-", ".tmp", getApplication<Application>().cacheDir)
                    try {
                        temp.outputStream().use { output ->
                            check(Net.fsDownloadTo(broker, path, output) { bytes, _ -> require(bytes <= WorkspaceBlobs.LIMIT) { "File exceeds 128 MiB" } }) { "File download failed" }
                            output.fd.sync()
                        }; temp
                    } catch (e: Exception) { temp.delete(); throw e }
                }
                try { artifactTransfers.stage(file.inputStream(), filename, null, panel, broker.brokerID, path) }
                finally { file.delete() }
                requestArtifacts(); refreshArtifactTransfers()
            } catch (e: Exception) { workspaceSelectionIssue = e.message; requestedScreen = SCREEN_WORKSPACE }
        }
    }
    fun requestDashboard() { requestedScreen = SCREEN_DASHBOARDS }
    var requestedDashboardID by mutableStateOf<String?>(null); private set
    fun consumeDashboardRequest() { requestedDashboardID = null }
    fun openSharedService(broker: Broker, port: Int, name: String) {
        try {
            val id = java.util.UUID.randomUUID().toString()
            val data = WorkspaceLocators.service(broker.brokerID, port, "/").put("name", name)
            workspace.enqueue("dashboards", id, data)
            requestedDashboardID = id; requestDashboard(); refreshWorkspace(true)
        } catch (e: Exception) { workspaceSelectionIssue = e.message; requestedScreen = SCREEN_WORKSPACE }
    }
    fun clearLabError() { labError = null }

    fun requestWeeklyProgress() {
        requestedScreen = SCREEN_WEEKLY_PROGRESS
        refreshWeeklyProgress(force = true)
    }

    fun weeklyProgressHost(): Broker? =
        brokers.firstOrNull { it.id == weeklyProgressHostId }
            ?: brokers.firstOrNull { it.isMac }

    fun refreshWeeklyProgress(force: Boolean = false) {
        if (weeklyProgressRefreshInFlight) return
        val now = android.os.SystemClock.elapsedRealtime()
        val minimumInterval = if (weeklyProgressCatalog.activeOperation == null) 15_000L else 2_000L
        if (!force && now - weeklyProgressLastRefreshAt < minimumInterval) return
        val preferred = weeklyProgressHost()
        // Broker metadata is enriched asynchronously during startup. Keep the
        // last proven provider eligible even before its OS field arrives.
        val candidates = brokers
            .filter { it.isMac || it.id == weeklyProgressHostId }
            .sortedBy { if (it.id == preferred?.id) 0 else 1 }
        if (candidates.isEmpty()) {
            weeklyProgressProviderAvailable = false
            if (weeklyProgressCatalog.projects.isEmpty()) {
                weeklyProgressError = "Your Mac broker is not available."
            }
            return
        }
        weeklyProgressRefreshInFlight = true
        weeklyProgressLastRefreshAt = now
        weeklyProgressRefreshing = true
        viewModelScope.launch {
            try {
                val answer = withContext(Dispatchers.IO) {
                    candidates.firstNotNullOfOrNull { broker ->
                        WeeklyProgressNet.catalog(broker)?.let { broker to it }
                    }
                }
                if (answer != null) {
                    weeklyProgressHostId = answer.first.id
                    prefs.edit().putString("ut.weeklyProgress.host", answer.first.id).apply()
                    weeklyProgressCatalog = answer.second.first
                    weeklyProgressProviderAvailable = true
                    weeklyProgressError = null
                    withContext(Dispatchers.IO) {
                        WeeklyProgressNet.saveCatalog(getApplication(), answer.second.second)
                    }
                } else {
                    weeklyProgressProviderAvailable = false
                    weeklyProgressError = if (weeklyProgressCatalog.projects.isEmpty())
                        "Open the updated Argus app on your Mac to use Weekly Progress."
                    else "The Mac is unavailable. Showing the last saved catalog."
                }
            } finally {
                weeklyProgressRefreshInFlight = false
                weeklyProgressRefreshing = false
            }
        }
    }

    fun generateWeeklyProgress(projectId: String, weekStart: String) {
        if (weeklyProgressActionBusy) return
        val host = weeklyProgressHost()
        if (host == null) {
            weeklyProgressError = "Your Mac broker is not available."
            return
        }
        val actionKey = "generate:$projectId:$weekStart"
        val preferenceKey = "ut.weeklyProgress.request.$actionKey"
        val requestId = prefs.getString(preferenceKey, null)
            ?: "android-${java.util.UUID.randomUUID()}".also {
                prefs.edit().putString(preferenceKey, it).apply()
            }
        weeklyProgressActionBusy = true
        weeklyProgressError = null
        viewModelScope.launch {
            val reply = withContext(Dispatchers.IO) {
                WeeklyProgressNet.generate(host, projectId, weekStart, requestId)
            }
            weeklyProgressActionBusy = false
            if (reply.successful) {
                prefs.edit().remove(preferenceKey).apply()
                delay(250)
                refreshWeeklyProgress(force = true)
            } else {
                // A transport failure may have happened after the Mac accepted
                // the command. Keep the id so an explicit retry is idempotent.
                if (reply.status in 400..499 && reply.status != 409) {
                    prefs.edit().remove(preferenceKey).apply()
                }
                weeklyProgressError = reply.error ?: when (reply.status) {
                    409 -> "Another Weekly Progress review is already running on the Mac."
                    503 -> "Open Argus on your Mac before starting a review."
                    else -> "The Mac could not start this review."
                }
                refreshWeeklyProgress(force = true)
            }
        }
    }

    fun resumeWeeklyProgress(generationId: String) {
        if (weeklyProgressActionBusy) return
        val host = weeklyProgressHost()
        if (host == null) {
            weeklyProgressError = "Your Mac broker is not available."
            return
        }
        val preferenceKey = "ut.weeklyProgress.resume.$generationId"
        val requestId = prefs.getString(preferenceKey, null)
            ?: "android-resume-${java.util.UUID.randomUUID()}".also {
                prefs.edit().putString(preferenceKey, it).apply()
            }
        weeklyProgressActionBusy = true
        weeklyProgressError = null
        viewModelScope.launch {
            val reply = withContext(Dispatchers.IO) {
                WeeklyProgressNet.resume(host, generationId, requestId)
            }
            weeklyProgressActionBusy = false
            if (reply.successful) {
                prefs.edit().remove(preferenceKey).apply()
                delay(250)
                refreshWeeklyProgress(force = true)
            } else {
                if (reply.status in 400..499 && reply.status != 409) {
                    prefs.edit().remove(preferenceKey).apply()
                }
                weeklyProgressError = reply.error ?: "The Mac could not resume this review."
                refreshWeeklyProgress(force = true)
            }
        }
    }

    fun clearWeeklyProgressError() { weeklyProgressError = null }

    fun changeUnattendedMode(enabled: Boolean) {
        if (unattendedModeUpdating) return
        val host = syncHost()
        if (host == null) {
            unattendedModeError = "The Mac broker is not available."
            return
        }
        val previous = unattendedMode
        unattendedMode = enabled
        unattendedModeUpdating = true
        unattendedModeError = null
        viewModelScope.launch {
            val ok = withContext(Dispatchers.IO) { LabNet.setUnattendedMode(host, enabled) }
            unattendedModeUpdating = false
            if (ok) {
                prefs.edit().putBoolean("ut.unattendedMode", enabled).apply()
                delay(750)
                refreshLab()
            } else {
                unattendedMode = previous
                unattendedModeError = "The Mac broker could not change Unattended Mode."
            }
        }
    }

    fun labDetailKey(card: LabSetCard, run: String) = "${card.id}/$run"

    private fun labSummaryFingerprint(run: LabRunSummary) = listOf(
        run.status, run.started.orEmpty(), run.stoppedAt.orEmpty(), run.stopReason.orEmpty(),
        run.latest.orEmpty(), run.latestAt.orEmpty(),
        run.exitCode.toString(), run.archived.toString(),
    ).joinToString("\u0000")

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

    fun markLabRunStopped(card: LabSetCard, run: String, reason: String) =
        labAction { withContext(Dispatchers.IO) { LabNet.markStopped(card, run, reason) } }

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

    fun hideLabScopeNotes(notes: List<Pair<LabNotesGroup, LabHubNote>>) = labAction {
        withContext(Dispatchers.IO) {
            notes.isNotEmpty() && notes.map { (group, note) ->
                LabNet.hide(group.broker, note.id, scope = note.scope, project = note.project.orEmpty())
            }.all { it }
        }
    }

    fun hideLabSetEvent(card: LabSetCard, target: String) = labAction {
        withContext(Dispatchers.IO) { LabNet.hide(card.broker, target, set = card.brief.set.id) }
    }

    // --- command center ----------------------------------------------------

    /** AI statuses published by the Mac, read per broker. Key = "<brokerId>/<session>". */
    val ccStatus = mutableStateMapOf<String, AgentCardStatus>()
    val ccIssues = mutableStateMapOf<String, String>()
    val ccCorrectionIssues = mutableStateMapOf<String, String>()
    private val ccRefreshInFlight = mutableSetOf<String>()
    private fun ccKey(b: Broker, name: String) = "${b.id}/$name"
    fun ccFor(b: Broker, name: String): AgentCardStatus? {
        val key = sharedSessionKey(b, name)
        if (workspace.loaded && key != null) {
            val value = workspace.data("cc-status", key)
            val override = workspace.data("cc-overrides", key)
            if (value != null || override != null) return AgentCardStatus(name,
                override?.optString("label") ?: value!!.optString("label", "idle"),
                value?.optString("summary").orEmpty(), value?.optString("lookAtThis")?.takeIf { it.isNotEmpty() },
                (value?.optDouble("updatedAt") ?: 0.0) / 1000)
            return null
        }
        val status = ccStatus[ccKey(b, name)]
        val lifetime = correctionLifetime(b, name) ?: return status
        val pending = corrections.current(correctionKey(b, name), lifetime) ?: return status
        return (status ?: AgentCardStatus(name, "idle", "", null, 0.0)).copy(label = pending.label)
    }

    // A status the user set on THIS device, shown optimistically until the Mac reflects
    // it back via /ccstatus — acknowledgment, not an arbitrary timer, ends pending.
    // label on the next poll before the Mac has processed the override.
    private val corrections = StatusCorrections(prefs.getString("ut.ccCorrections.v1", null)) {
        check(prefs.edit().putString("ut.ccCorrections.v1", it).commit()) { "Could not save the pending status change." }
    }
    private val correctionWrites = mutableMapOf<String, Mutex>()
    private fun correctionKey(b: Broker, name: String) = workspace.workspaceID + "/" + ccKey(b, name)
    private fun correctionLifetime(b: Broker, name: String): String? = sessions[b.id].orEmpty().firstOrNull { it.name == name }?.let {
        b.httpBase + "/" + it.lineageID.ifEmpty { it.tmuxId ?: it.name }
    }
    internal var sendStatusCorrection: suspend (Broker, String, String) -> Long? = { b, name, label ->
        withContext(Dispatchers.IO) { Net.setCCOverride(b, name, label) }
    }

    /** Manually set a card's status from the phone: optimistic locally + relayed to the
     *  Mac (the only generator) via the broker, which applies it and re-publishes. */
    fun setManualStatus(b: Broker, name: String, label: String) {
        if (label !in listOf("working", "idle", "needs-decision", "stuck", "milestone", "look", "drifting")) {
            ccCorrectionIssues[b.id] = "Unknown status label."; return
        }
        ccCorrectionIssues.remove(b.id)
        val identity = sharedSessionKey(b, name)
        if (identity != null) {
            try {
                workspace.enqueue("cc-overrides", identity, JSONObject().put("label", label)
                    .put("commandID", java.util.UUID.randomUUID().toString()).put("actor", "human"))
                refreshWorkspace(force = true)
            } catch (e: Exception) { ccCorrectionIssues[b.id] = "Could not save status for $name: ${e.message}" }
            return
        }
        val lifetime = correctionLifetime(b, name)
        if (lifetime == null) { ccCorrectionIssues[b.id] = "The session is no longer available."; return }
        val key = correctionKey(b, name)
        val pending = try { corrections.begin(key, lifetime, label, ccStatus[ccKey(b, name)]) }
            catch (e: Exception) { ccCorrectionIssues[b.id] = e.message ?: "Could not save status."; return }
        val lock = correctionWrites.getOrPut(key) { Mutex() }
        viewModelScope.launch {
            try {
                lock.withLock {
                    if (key != correctionKey(b, name) || lifetime != correctionLifetime(b, name) || corrections.current(key, lifetime)?.id != pending.id) return@withLock
                    corrections.accepted(key, pending, sendStatusCorrection(b, name, label))
                }
            } catch (e: Exception) {
                val current = corrections.current(key, lifetime)?.id == pending.id
                runCatching { corrections.reject(key, pending) }
                if (current && key == correctionKey(b, name) && lifetime == correctionLifetime(b, name)) {
                    ccCorrectionIssues[b.id] = "Could not save status for $name: ${e.message}"
                }
            }
        }
    }

    /** Pull each broker's /ccstatus and merge (each broker holds only its own sessions). */
    fun refreshCC() {
        brokers.toList().forEach { b ->
            // Read and write routing must use the same per-session capability;
            // a broker identity alone does not guarantee every session has one.
            if (workspace.loaded && sessions[b.id].orEmpty().all { sharedSessionKey(b, it.name) != null }) { ccIssues.remove(b.id); return@forEach }
            if (!ccRefreshInFlight.add(b.id)) return@forEach
            viewModelScope.launch {
              try {
                val workspaceID = workspace.workspaceID
                val lifetimes = sessions[b.id].orEmpty().associate { it.name to correctionLifetime(b, it.name) }
                val items = withContext(Dispatchers.IO) { Net.ccStatus(b) }
                if (items == null) { ccIssues[b.id] = "Status refresh unavailable; showing last known status."; return@launch }
                if (brokers.none { it.id == b.id } || workspaceID != workspace.workspaceID) return@launch
                ccIssues.remove(b.id)
                val prefix = "${b.id}/"
                val live = HashSet<String>()
                items.forEach { item ->
                    val k = ccKey(b, item.session)
                    val lifetime = lifetimes[item.session] ?: return@forEach
                    if (lifetime != correctionLifetime(b, item.session)) return@forEach
                    val prior = ccStatus[k]
                    if (prior != null && item.updatedAt < prior.updatedAt) { live.add(k); return@forEach }
                    corrections.merge(correctionKey(b, item.session), lifetime, item)
                    ccStatus[k] = item
                    live.add(k)
                }
                ccStatus.keys.filter { it.startsWith(prefix) && it !in live }.forEach { ccStatus.remove(it) }
              } catch (e: Exception) {
                ccIssues[b.id] = "Status refresh failed: ${e.message}"
              } finally { ccRefreshInFlight.remove(b.id) }
            }
        }
    }

    /** Sessions the user has "ticked" to set aside in the command center. Key = "<id> name". */
    val backlog = mutableStateListOf<String>().also { it.addAll((prefs.getString("backlog", "") ?: "").split("\n").filter(String::isNotEmpty)) }
    private fun blKey(b: Broker, name: String) = "${b.id} $name"
    fun isBacklogged(b: Broker, name: String): Boolean {
        val key = sharedSessionKey(b, name)
        if (workspace.loaded && key != null) return workspace.data("session-backlog", key)?.optBoolean("value") ?: false
        return backlog.contains(blKey(b, name))
    }
    fun toggleBacklog(b: Broker, name: String) {
        val sharedKey = sharedSessionKey(b, name)
        if (workspace.loaded && sharedKey != null) {
            changeShared("session-backlog", sharedKey, JSONObject().put("value", !isBacklogged(b, name)))
            return
        }
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
                .filter { !it.hidden && it.state == "waiting" &&
                    if (workspace.loaded && it.activityRevision > 0 && sharedSessionKey(b, it.name) != null) !isSharedRead(b, it)
                    else unseenKey(b, it.name) !in acknowledged }
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
    fun workspaceHost(): Broker? = brokers.firstOrNull { it.workspaceEnabled && it.workspaceID == workspace.workspaceID }
    private fun syncHost(): Broker? = workspaceHost()

    fun selectWorkspace(broker: Broker) {
        if (workspaceRefreshInFlight || workspaceSyncInflight.isNotEmpty()) { workspaceSelectionIssue = "Wait for the current sync to finish."; return }
        if (!broker.workspaceEnabled || broker.workspaceID.isEmpty()) { workspaceSelectionIssue = "This broker is not a workspace host."; return }
        val previous = workspace.workspaceID
        if (previous != broker.workspaceID) {
            // Store documents and merge baselines per workspace. Switching hosts
            // must never import another workspace's records as new local edits.
            val keys = listOf("ut.workflows.v1", "ut.todoBoards.v1", "ut.notes.v1", "ut.planner.v1") +
                listOf("workflows", "todos", "notes", "planner").flatMap { listOf("ut.sync.base.$it", "ut.sync.conflict.$it") }
            val saved = JSONObject()
            keys.forEach { key -> prefs.getString(key, null)?.let { saved.put(key, it) } }
            val editor = prefs.edit()
            if (previous.isNotEmpty()) editor.putString("ut.documents.$previous", saved.toString())
            val target = prefs.getString("ut.documents.${broker.workspaceID}", null)?.let(::JSONObject)
            if (previous.isNotEmpty() || target != null) keys.forEach { key ->
                if (target?.has(key) == true) editor.putString(key, target.getString(key)) else editor.remove(key)
            }
            check(editor.putString("ut.workspace.id", broker.workspaceID).commit()) { "Could not save workspace selection." }
            workspace.bind(broker.workspaceID)
            if (previous.isNotEmpty() || target != null) {
                workflows.clear(); todoBoards.clear(); notes.clear(); planner.clear()
                workflowsTs = 0; todosTs = 0; notesTs = 0; plannerTs = 0
                workspaceSyncIssues.clear(); loadUserData()
            }
        }
        workspaceSelectionIssue = null
        refreshWorkspace(force = true)
    }

    fun refreshWorkspace(force: Boolean = false) {
        if (workspaceRefreshInFlight) return
        if (workspace.workspaceID.isEmpty()) {
            val candidates = brokers.filter { it.workspaceEnabled && it.workspaceID.isNotEmpty() }.distinctBy { it.workspaceID }
            if (candidates.size == 1) { selectWorkspace(candidates.single()); return }
            workspaceSelectionIssue = if (candidates.isEmpty()) "No shared workspace host is connected." else "Choose a workspace host."
            return
        }
        val host = workspaceHost()
        if (host == null) { workspaceSelectionIssue = "Workspace host is offline; cached data and pending changes are retained."; return }
        workspaceSelectionIssue = null; workspaceRefreshInFlight = true
        viewModelScope.launch {
            try {
                workspace.synchronize(host, force)
                if (workspace.loaded) migrateSessionMarks()
            } finally { workspaceRefreshInFlight = false }
        }
    }

    fun sharedSessionKey(b: Broker, name: String): String? {
        val broker = brokers.firstOrNull { it.id == b.id } ?: b
        val session = sessions[b.id].orEmpty().firstOrNull { it.name == name } ?: return null
        if (broker.brokerID.isEmpty() || session.lineageID.isEmpty()) return null
        return "${broker.brokerID}/${session.lineageID}"
    }
    private fun isSharedRead(b: Broker, session: SessionInfo?): Boolean {
        if (session == null || session.activityRevision == 0L) return false
        val key = sharedSessionKey(b, session.name) ?: return false
        return (workspace.data("session-read", key)?.optLong("seenRevision") ?: 0L) >= session.activityRevision
    }
    private fun acknowledgeShared(b: Broker, name: String) {
        if (!workspace.loaded) return
        val session = sessions[b.id].orEmpty().firstOrNull { it.name == name } ?: return
        val key = sharedSessionKey(b, name) ?: return
        if (session.activityRevision == 0L || isSharedRead(b, session)) return
        changeShared("session-read", key, JSONObject().put("seenRevision", session.activityRevision))
    }
    fun changeShared(collection: String, id: String, data: JSONObject?, delete: Boolean = false) {
        try { workspace.enqueue(collection, id, data, delete); refreshWorkspace(force = true) }
        catch (e: Exception) { workspaceSelectionIssue = e.message }
    }
    private fun migrateSessionMarks() {
        brokers.forEach { b -> sessions[b.id].orEmpty().forEach { session ->
            val key = sharedSessionKey(b, session.name) ?: return@forEach
            val marker = "ut.migrated.backlog.${workspace.workspaceID}.${blKey(b, session.name)}"
            if (prefs.getBoolean(marker, false)) return@forEach
            if (backlog.contains(blKey(b, session.name)) && workspace.record("session-backlog", key) == null && workspace.data("session-backlog", key) == null) {
                workspace.enqueue("session-backlog", key, JSONObject().put("value", true))
            }
            prefs.edit().putBoolean(marker, true).apply()
        } }
    }

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
        UserDataJson.parsePlanner(prefs.getString("ut.planner.v1", null))?.let { (ts, list) ->
            plannerTs = ts; planner.clear(); planner.addAll(list)
        }
    }
    private fun savePlannerLocal() {
        check(prefs.edit().putString("ut.planner.v1", UserDataJson.plannerEnvelope(plannerTs, planner.toList())).commit()) { "Could not save Planner." }
    }
    fun savePlan(item: PlannerCommitment) {
        val index = planner.indexOfFirst { it.id == item.id }
        val next = item.copy(title = item.title.trim(), project = item.project.trim(), editedAt = nowIso())
        if (next.title.isEmpty()) return
        if (index < 0) planner.add(next) else planner[index] = next
        plannerTs = now(); savePlannerLocal(); syncUserData()
    }
    fun togglePlan(item: PlannerCommitment) = savePlan(item.copy(completedAt = if (item.isCompleted) null else nowIso()))
    fun deletePlan(item: PlannerCommitment) {
        planner.removeAll { it.id == item.id }; plannerTs = now(); savePlannerLocal(); syncUserData()
    }
    private fun saveWorkflowsLocal() {
        prefs.edit().putString("ut.workflows.v1", UserDataJson.workflowsEnvelope(workflowsTs, workflows.toList())).apply()
    }
    private fun saveTodosLocal() {
        prefs.edit().putString("ut.todoBoards.v1", UserDataJson.todosEnvelope(todosTs, todoBoards.toList())).apply()
    }
    private fun touchWorkflows(destructive: Boolean = false) {
        if (destructive) {
            workflowsDestructive = true
            prefs.edit().putBoolean("ut.workflows.pendingDestructive", true).apply()
        }
        workflowsTs = now(); saveWorkflowsLocal()
        syncUserData()
    }
    private fun touchTodos(destructive: Boolean = false) {
        if (destructive) {
            todosDestructive = true
            prefs.edit().putBoolean("ut.todos.pendingDestructive", true).apply()
        }
        todosTs = now(); saveTodosLocal()
        syncUserData()
    }

    fun upsertWorkflow(w: Workflow) {
        val i = workflows.indexOfFirst { it.id == w.id }
        if (i >= 0) workflows[i] = w else workflows.add(w)
        touchWorkflows()
    }
    fun deleteWorkflow(w: Workflow) {
        if (workflows.removeAll { it.id == w.id }) touchWorkflows(destructive = true)
    }

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
        if (items.size == todoBoards[i].items.size) return
        todoBoards[i] = todoBoards[i].copy(items = items); touchTodos(destructive = true)
    }
    fun deleteBoard(boardId: String) {
        if (todoBoards.removeAll { it.id == boardId && !it.isMisc }) touchTodos(destructive = true)
    }

    // -- Notes Hub: bump+save on edit; the reconcile pushes (no POST per keystroke) --
    private fun saveNotesLocal() { prefs.edit().putString("ut.notes.v1", UserDataJson.notesEnvelope(notesTs, notes.toList())).apply() }
    private fun touchNotes(destructive: Boolean = false) {
        if (destructive) {
            notesDestructive = true
            prefs.edit().putBoolean("ut.notes.pendingDestructive", true).apply()
        }
        notesTs = now(); saveNotesLocal()
    }
    fun addNote(): String { val n = Note(); notes.add(n); touchNotes(); return n.id }
    fun updateNoteText(id: String, text: String) {
        val i = notes.indexOfFirst { it.id == id }; if (i < 0) return
        notes[i] = notes[i].copy(text = text, editedAt = nowIso()); touchNotes()
    }
    fun toggleNote(id: String) {
        val i = notes.indexOfFirst { it.id == id }; if (i < 0) return
        notes[i] = notes[i].copy(done = !notes[i].done); touchNotes()
    }
    fun deleteNote(id: String) {
        if (notes.removeAll { it.id == id }) touchNotes(destructive = true)
    }

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
            if (System.currentTimeMillis() - (identityRefreshedAt[b.id] ?: 0) < 30_000 || !identityRefreshInFlight.add(b.id)) return@forEach
            viewModelScope.launch {
              try {
                val probed = withContext(Dispatchers.IO) { Net.probe(b.host) }
                if (probed != null) {
                    val i = brokers.indexOfFirst { it.host == b.host }
                    if (i >= 0) { brokers[i] = probed; saveBrokers() }
                }
                identityRefreshedAt[b.id] = System.currentTimeMillis()
              } finally { identityRefreshInFlight.remove(b.id) }
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

    private fun workspaceData(key: String): JSONArray {
        val raw = when (key) {
            "planner" -> UserDataJson.plannerEnvelope(plannerTs, planner.toList())
            "notes" -> UserDataJson.notesEnvelope(notesTs, notes.toList())
            "todos" -> UserDataJson.todosEnvelope(todosTs, todoBoards.toList())
            else -> UserDataJson.workflowsEnvelope(workflowsTs, workflows.toList())
        }
        return JSONObject(raw).getJSONArray("data")
    }
    private fun applyWorkspaceData(key: String, data: JSONArray, ts: Long) {
        val envelope = JSONObject().put("updatedAt", ts).put("data", data).toString()
        when (key) {
            "planner" -> {
                val parsed = UserDataJson.parsePlanner(envelope) ?: error("Invalid planner")
                planner.clear(); planner.addAll(parsed.second); plannerTs = ts; savePlannerLocal()
            }
            "notes" -> {
                val parsed = UserDataJson.parseNotes(envelope) ?: error("Invalid notes")
                notes.clear(); notes.addAll(parsed.second); notesTs = ts; saveNotesLocal()
            }
            "todos" -> {
                val parsed = UserDataJson.parseTodos(envelope) ?: error("Invalid todos")
                todoBoards.clear(); todoBoards.addAll(parsed.second); todosTs = ts; saveTodosLocal()
            }
            "workflows" -> {
                val parsed = UserDataJson.parseWorkflows(envelope) ?: error("Invalid workflows")
                workflows.clear(); workflows.addAll(parsed.second); workflowsTs = ts; saveWorkflowsLocal()
            }
        }
    }
    private fun commitWorkspaceData(key: String, data: JSONArray, base: JSONArray, ts: Long) {
        UserDataJson.validateWorkspace(key, data)
        val localKey = when(key) { "notes" -> "ut.notes.v1"; "todos" -> "ut.todoBoards.v1"; "planner" -> "ut.planner.v1"; else -> "ut.workflows.v1" }
        val envelope = JSONObject().put("updatedAt", ts).put("data", data).toString()
        check(prefs.edit().putString(localKey, envelope).putString("ut.sync.base.$key", base.toString())
            .remove("ut.sync.conflict.$key").commit()) { "Could not persist synchronized workspace." }
        applyWorkspaceData(key, data, ts)
    }
    fun workspaceConflict(key: String): String? = prefs.getString("ut.sync.conflict.$key", null)
    fun resolveWorkspaceConflict(key: String, expected: String, document: String) {
        check(workspaceConflict(key) == expected) { "Conflict changed. Review it again." }
        val conflict = JSONObject(expected)
        check(WorkspaceMerge.equal(workspaceData(key), conflict.getJSONArray("local"))) { "Local data changed. Review it again." }
        val result = JSONArray(document)
        commitWorkspaceData(key, result, conflict.getJSONArray("remote"), now())
        workspaceSyncIssues.remove(key); syncUserData()
    }
    fun syncUserData() {
        val h = syncHost() ?: return
        for (key in listOf("workflows", "todos", "notes", "planner")) {
            if (key in workspaceSyncInflight) continue
            val conflict = workspaceConflict(key)
            if (conflict != null) {
                val refreshed = JSONObject(conflict).put("local", workspaceData(key))
                prefs.edit().putString("ut.sync.conflict.$key", refreshed.toString()).apply()
                workspaceSyncIssues[key] = "Concurrent edits need review; both copies are preserved."
                continue
            }
            workspaceSyncInflight.add(key)
            val base = JSONArray(prefs.getString("ut.sync.base.$key", null) ?: "[]")
            val sent = workspaceData(key)
            viewModelScope.launch {
                try {
                    val body = JSONObject().put("base", base).put("data", sent).toString()
                    val response = withContext(Dispatchers.IO) { Net.mergeUserData(h, key, body) }
                        ?: error("Sync host unavailable; local changes are retained.")
                    val value = JSONObject(response.second)
                    var remote: JSONArray
                    var merged: JSONArray? = null
                    if (response.first == 409 && value.has("current")) {
                        remote = value.getJSONArray("current")
                    } else {
                        check(response.first == 200) { "Sync requires an updated broker (HTTP ${response.first}). Local edits are retained." }
                        remote = value.getJSONArray("data")
                        try { merged = WorkspaceMerge.merge(sent, workspaceData(key), remote) as JSONArray }
                        catch (_: IllegalStateException) { }
                    }
                    if (merged == null) {
                        val preserved = JSONObject().put("base", base).put("local", workspaceData(key)).put("remote", remote)
                        check(prefs.edit().putString("ut.sync.conflict.$key", preserved.toString()).commit())
                        workspaceSyncIssues[key] = "Concurrent edits need review; both copies are preserved."
                    } else {
                        val oldBase = prefs.getString("ut.sync.base.$key", null)
                        if (oldBase == null || !WorkspaceMerge.equal(JSONArray(oldBase), remote) || !WorkspaceMerge.equal(workspaceData(key), merged)) {
                            commitWorkspaceData(key, merged, remote, value.optLong("updatedAt", now()))
                        }
                        workspaceSyncIssues.remove(key)
                    }
                } catch (e: Exception) { workspaceSyncIssues[key] = e.message ?: "Sync failed; local changes are retained." }
                finally { workspaceSyncInflight.remove(key) }
            }
        }
    }
}
