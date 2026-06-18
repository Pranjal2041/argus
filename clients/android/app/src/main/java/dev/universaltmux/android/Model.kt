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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** App state: the saved brokers, their sessions, and the current selection. */
class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("ut", 0)

    val brokers = mutableStateListOf<Broker>()
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

    init {
        loadBrokers()
        loadWandb()
        refreshAll()
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

    private fun discoverViaTailnet() {
        viewModelScope.launch {
            val found = withContext(Dispatchers.IO) { TsnetCore.discover() }
            found.forEach { b ->
                val i = brokers.indexOfFirst { it.host == b.host }
                if (i >= 0) brokers[i] = b else brokers.add(b)
            }
            if (found.isNotEmpty()) saveBrokers()
            found.forEach { refresh(it) }
        }
    }

    private fun loadBrokers() {
        val arr = JSONArray(prefs.getString("brokers", "[]") ?: "[]")
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            brokers.add(Broker(o.getString("host"), o.getString("scheme"), o.optString("name", o.getString("host"))))
        }
    }

    private fun saveBrokers() {
        val arr = JSONArray()
        brokers.forEach { arr.put(JSONObject().put("host", it.host).put("scheme", it.scheme).put("name", it.name)) }
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
            val existing = brokers.indexOfFirst { it.host == probed.host }
            if (existing >= 0) brokers[existing] = probed else brokers.add(probed)
            saveBrokers()
            refresh(probed)
        }
    }

    fun removeBroker(b: Broker) {
        brokers.removeAll { it.id == b.id }
        sessions.remove(b.id)
        if (selected?.first?.id == b.id) selected = null
        saveBrokers()
    }

    fun refreshAll() {
        brokers.toList().forEach { refresh(it) }
        if (TsnetCore.isUp) discoverViaTailnet()
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
}
