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

    init {
        loadBrokers()
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
            (sessions[b.id] ?: emptyList())
                .filter { it.state == "waiting" && unseenKey(b, it.name) !in acknowledged }
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
