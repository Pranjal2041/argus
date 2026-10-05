package dev.universaltmux.android

import androidx.compose.runtime.mutableStateMapOf
import org.json.JSONObject
import java.util.UUID

/** Native-relay corrections are scoped to their session incarnation, never used
 * as shared session IDs. A fresh matching publication acknowledges the change. */
internal class StatusCorrections(saved: String? = null, private val save: (String) -> Unit = {}) {
    data class Pending(val id: String, val lifetime: String, val label: String, val previous: AgentCardStatus?, val receipt: Long? = null)
    private val pending = mutableStateMapOf<String, Pending>()
    init {
        runCatching { JSONObject(saved ?: "{}").also { root -> root.keys().forEach { key ->
            val v = root.getJSONObject(key); val p = v.optJSONObject("previous")
            pending[key] = Pending(v.getString("id"), v.getString("lifetime"), v.getString("label"), p?.let {
                AgentCardStatus(it.getString("session"), it.getString("label"), it.getString("summary"), it.optString("lookAtThis").ifEmpty { null }, it.getDouble("updatedAt"))
            }, if (v.has("receipt")) v.getLong("receipt") else null)
        } } }
    }
    private fun commit(next: Map<String, Pending>) {
        val root = JSONObject()
        next.forEach { (key, v) -> root.put(key, JSONObject().put("id", v.id).put("lifetime", v.lifetime).put("label", v.label).put("receipt", v.receipt).also { row ->
            v.previous?.let { p -> row.put("previous", JSONObject().put("session", p.session).put("label", p.label).put("summary", p.summary).put("lookAtThis", p.lookAtThis).put("updatedAt", p.updatedAt)) }
        }) }
        save(root.toString()); pending.clear(); pending.putAll(next)
    }
    fun current(key: String, lifetime: String) = pending[key]?.takeIf { it.lifetime == lifetime }
    fun discardMatching(matches: (String) -> Boolean) { commit(pending.filterKeys { !matches(it) }) }
    fun begin(key: String, lifetime: String, label: String, previous: AgentCardStatus?): Pending {
        val value = Pending(UUID.randomUUID().toString(), lifetime, label, current(key, lifetime)?.previous ?: previous)
        commit(pending.toMap() + (key to value)); return value
    }
    fun reject(key: String, value: Pending): Boolean {
        if (pending[key]?.id != value.id) return false
        commit(pending.toMap() - key); return true
    }
    fun accepted(key: String, value: Pending, receipt: Long?) {
        if (pending[key]?.id == value.id) commit(pending.toMap() + (key to value.copy(receipt = receipt)))
    }
    fun merge(key: String, lifetime: String, status: AgentCardStatus): AgentCardStatus {
        val value = current(key, lifetime) ?: return status
        val acknowledged = (value.receipt?.let { (status.appliedOverrideTS ?: 0L) >= it } ?: false) ||
            (status.label == value.label && status.updatedAt > (value.previous?.updatedAt ?: 0.0))
        if (acknowledged) {
            commit(pending.toMap() - key); return status
        }
        return status.copy(label = value.label)
    }
}
