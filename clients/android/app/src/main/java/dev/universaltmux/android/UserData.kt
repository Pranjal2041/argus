package dev.universaltmux.android

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID

/** Uppercase UUID to match Swift's encoding (Foundation emits canonical uppercase). */
fun newId(): String = UUID.randomUUID().toString().uppercase(Locale.ROOT)

/** ISO-8601 truncated to whole seconds + 'Z' — the exact shape Swift's `.iso8601`
 *  strategy reads/writes, so timestamps round-trip Mac <-> phone without a parse fail. */
fun nowIso(): String = Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()

// ---- Workflows -------------------------------------------------------------
data class Workflow(
    val id: String = newId(),
    var name: String = "",
    var machine: String = "",
    var folder: String = "",
    var commands: String = "",
    var notes: String = "",
    var colorHex: String = ""
)

// ---- Todo Maps -------------------------------------------------------------
data class TodoItem(
    val id: String = newId(),
    var text: String = "",
    var done: Boolean = false,
    val createdAt: String = nowIso(),
    var completedAt: String? = null
)

data class TodoBoard(
    val id: String = newId(),
    var machine: String = "",
    var session: String = "",
    var isMisc: Boolean = false,
    var items: MutableList<TodoItem> = mutableListOf()
) {
    val pending: Int get() = items.count { !it.done }
}

/** JSON for the /userdata sync envelopes — kept byte-compatible with the Mac's Codable. */
object UserDataJson {
    fun parseWorkflows(envelope: String?): Pair<Long, List<Workflow>>? {
        if (envelope == null) return null
        return try {
            val o = JSONObject(envelope)
            if (!o.has("updatedAt") || !o.has("data")) return null
            val arr = o.getJSONArray("data")
            val list = (0 until arr.length()).map { i ->
                val w = arr.getJSONObject(i)
                Workflow(w.optString("id", newId()), w.optString("name"), w.optString("machine"),
                    w.optString("folder"), w.optString("commands"), w.optString("notes"), w.optString("colorHex"))
            }
            o.getLong("updatedAt") to list
        } catch (_: Exception) { null }
    }

    fun workflowsEnvelope(updatedAt: Long, list: List<Workflow>): String {
        val arr = JSONArray()
        list.forEach { w ->
            arr.put(JSONObject().put("id", w.id).put("name", w.name).put("machine", w.machine)
                .put("folder", w.folder).put("commands", w.commands).put("notes", w.notes).put("colorHex", w.colorHex))
        }
        return JSONObject().put("updatedAt", updatedAt).put("data", arr).toString()
    }

    fun parseTodos(envelope: String?): Pair<Long, List<TodoBoard>>? {
        if (envelope == null) return null
        return try {
            val o = JSONObject(envelope)
            if (!o.has("updatedAt") || !o.has("data")) return null
            val arr = o.getJSONArray("data")
            val list = (0 until arr.length()).map { i ->
                val b = arr.getJSONObject(i)
                val ia = b.optJSONArray("items") ?: JSONArray()
                val items = (0 until ia.length()).map { j ->
                    val it = ia.getJSONObject(j)
                    val completed = if (!it.has("completedAt") || it.isNull("completedAt")) null
                                    else it.optString("completedAt")
                    TodoItem(it.optString("id", newId()), it.optString("text"), it.optBoolean("done"),
                        it.optString("createdAt", nowIso()), completed)
                }.toMutableList()
                TodoBoard(b.optString("id", newId()), b.optString("machine"), b.optString("session"),
                    b.optBoolean("isMisc"), items)
            }
            o.getLong("updatedAt") to list
        } catch (_: Exception) { null }
    }

    fun todosEnvelope(updatedAt: Long, list: List<TodoBoard>): String {
        val arr = JSONArray()
        list.forEach { board ->
            val items = JSONArray()
            board.items.forEach { it ->
                val o = JSONObject().put("id", it.id).put("text", it.text).put("done", it.done).put("createdAt", it.createdAt)
                if (it.completedAt != null) o.put("completedAt", it.completedAt)   // omit when null, like Swift
                items.put(o)
            }
            arr.put(JSONObject().put("id", board.id).put("machine", board.machine).put("session", board.session)
                .put("isMisc", board.isMisc).put("items", items))
        }
        return JSONObject().put("updatedAt", updatedAt).put("data", arr).toString()
    }
}
