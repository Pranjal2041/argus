package dev.universaltmux.android

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** The same record-ID three-way merge as the Mac and broker. */
object WorkspaceMerge {
    fun equal(a: Any?, b: Any?): Boolean = canonical(a) == canonical(b)
    fun canonical(v: Any?): String = when (v) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> v.keys().asSequence().toList().sorted().joinToString(prefix = "{", postfix = "}") { JSONObject.quote(it) + ":" + canonical(v.opt(it)) }
        is JSONArray -> (0 until v.length()).joinToString(prefix = "[", postfix = "]") { canonical(v.get(it)) }
        is String -> JSONObject.quote(v)
        else -> v.toString()
    }
    private fun records(v: Any?): Map<String, Any>? {
        if (v == null || v == JSONObject.NULL) return emptyMap()
        if (v !is JSONArray) return null
        val out = mutableMapOf<String, Any>()
        for (i in 0 until v.length()) {
            val item = v.optJSONObject(i) ?: return null
            val id = item.optString("id")
            if (id.isEmpty() || out.containsKey(id)) return null
            out[id] = item
        }
        return out
    }
    fun merge(base: Any?, local: Any?, remote: Any?, path: String = ""): Any? {
        if (equal(local, base)) return remote
        if (equal(remote, base) || equal(local, remote)) return local
        if (local is JSONObject && remote is JSONObject && (base is JSONObject || base == null || base == JSONObject.NULL)) {
            val b = base as? JSONObject ?: JSONObject()
            val keys = (b.keys().asSequence() + local.keys().asSequence() + remote.keys().asSequence()).toSet().sorted()
            val out = JSONObject()
            for (key in keys) {
                val value = merge(b.opt(key), local.opt(key), remote.opt(key), "$path/$key")
                if (value != null && value != JSONObject.NULL) out.put(key, value)
            }
            return out
        }
        val b = records(base); val l = records(local); val r = records(remote)
        if (b != null && l != null && r != null) {
            val out = JSONArray()
            for (key in (b.keys + l.keys + r.keys).sorted()) {
                val value = merge(b[key], l[key], r[key], "$path/$key")
                if (value != null && value != JSONObject.NULL) out.put(value)
            }
            return out
        }
        if ((path.endsWith("/editedAt") || path.endsWith("/updatedAt")) && local is String && remote is String) {
            try { return if (Instant.parse(local) > Instant.parse(remote)) local else remote } catch (_: Exception) { }
        }
        throw IllegalStateException("Concurrent edit at $path. Both copies are preserved.")
    }
}
