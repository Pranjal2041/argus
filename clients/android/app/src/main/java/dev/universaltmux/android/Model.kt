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
    var selected by mutableStateOf<Pair<Broker, String>?>(null)
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

    fun refresh(b: Broker) {
        viewModelScope.launch {
            val list = withContext(Dispatchers.IO) { Net.sessions(b) }
            if (list != null) sessions[b.id] = list
        }
    }

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
