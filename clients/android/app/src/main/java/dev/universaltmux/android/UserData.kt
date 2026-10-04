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

// ---- Notes Hub -------------------------------------------------------------
data class Note(
    val id: String = newId(),
    var text: String = "",
    var done: Boolean = false,
    val createdAt: String = nowIso(),
    var editedAt: String = nowIso()   // last content edit — drives time grouping/sort
)

data class PlannerCommitment(
    val id: String = newId(), val title: String = "", val project: String = "",
    val deadline: String = nowIso(), val hasExactTime: Boolean = true,
    val createdAt: String = nowIso(), val editedAt: String = nowIso(), val completedAt: String? = null,
    val original: String = "{}",
) {
    val isCompleted get() = completedAt != null
    fun effectiveDeadline(zone: java.time.ZoneId = java.time.ZoneId.systemDefault()): Instant {
        val instant = Instant.parse(deadline)
        return if (hasExactTime) instant else instant.atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toInstant().minusSeconds(1)
    }
}

/** JSON for the /userdata sync envelopes — kept byte-compatible with the Mac's Codable. */
object UserDataJson {
    /** Reject lossy/invalid review documents before changing either data or sync baseline. */
    fun validateWorkspace(key: String, data: JSONArray) {
        val ids = mutableSetOf<String>()
        val itemIds = mutableSetOf<String>()
        fun requireId(record: JSONObject, seen: MutableSet<String>) {
            val id = record.getString("id")
            java.util.UUID.fromString(id)
            require(seen.add(id.lowercase())) { "Duplicate record ID: $id" }
        }
        for (i in 0 until data.length()) {
            val record = data.getJSONObject(i)
            requireId(record, ids)
            if (key == "todos") {
                val items = record.getJSONArray("items")
                for (j in 0 until items.length()) requireId(items.getJSONObject(j), itemIds)
            }
        }
        val envelope = JSONObject().put("updatedAt", 1L).put("data", data).toString()
        val decoded = when (key) {
            "notes" -> notesEnvelope(1L, requireNotNull(parseNotes(envelope)).second)
            "todos" -> todosEnvelope(1L, requireNotNull(parseTodos(envelope)).second)
            "workflows" -> workflowsEnvelope(1L, requireNotNull(parseWorkflows(envelope)).second)
            "planner" -> plannerEnvelope(1L, requireNotNull(parsePlanner(envelope)).second)
            else -> error("Unknown workspace collection")
        }
        require(WorkspaceMerge.equal(data, JSONObject(decoded).getJSONArray("data"))) {
            "Document contains unsupported fields or invalid values. Both copies are retained."
        }
    }
    private fun envelope(updatedAt: Long, data: JSONArray, allowDestructive: Boolean): String {
        val out = JSONObject().put("updatedAt", updatedAt).put("data", data)
        if (allowDestructive) out.put("allowDestructive", true)
        return out.toString()
    }

    fun parsePlanner(envelope: String?): Pair<Long, List<PlannerCommitment>>? = try {
        if (envelope == null) null else {
            val root = JSONObject(envelope)
            val array = root.getJSONArray("data")
            val records = (0 until array.length()).map { index ->
                val o = array.getJSONObject(index)
                val id = o.getString("id"); UUID.fromString(id)
                val deadline = o.getString("deadline"); Instant.parse(deadline)
                val created = o.getString("createdAt"); Instant.parse(created)
                val edited = o.getString("editedAt"); Instant.parse(edited)
                val completed = if (o.has("completedAt") && !o.isNull("completedAt")) o.getString("completedAt").also { Instant.parse(it) } else null
                PlannerCommitment(id, o.getString("title"), o.optString("project"), deadline, o.optBoolean("hasExactTime", true), created, edited, completed, o.toString())
            }
            root.getLong("updatedAt") to records
        }
    } catch (_: Exception) { null }

    fun plannerEnvelope(updatedAt: Long, list: List<PlannerCommitment>): String = envelope(updatedAt, JSONArray().also { array ->
        list.forEach { item ->
            val o = JSONObject(item.original).put("id", item.id).put("title", item.title).put("project", item.project)
                .put("deadline", item.deadline).put("hasExactTime", item.hasExactTime).put("createdAt", item.createdAt).put("editedAt", item.editedAt)
            if (item.completedAt != null) o.put("completedAt", item.completedAt) else o.remove("completedAt")
            array.put(o)
        }
    }, false)

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

    fun workflowsEnvelope(updatedAt: Long, list: List<Workflow>, allowDestructive: Boolean = false): String {
        val arr = JSONArray()
        list.forEach { w ->
            arr.put(JSONObject().put("id", w.id).put("name", w.name).put("machine", w.machine)
                .put("folder", w.folder).put("commands", w.commands).put("notes", w.notes).put("colorHex", w.colorHex))
        }
        return envelope(updatedAt, arr, allowDestructive)
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

    fun todosEnvelope(updatedAt: Long, list: List<TodoBoard>, allowDestructive: Boolean = false): String {
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
        return envelope(updatedAt, arr, allowDestructive)
    }

    fun parseNotes(envelope: String?): Pair<Long, List<Note>>? {
        if (envelope == null) return null
        return try {
            val o = JSONObject(envelope)
            if (!o.has("updatedAt") || !o.has("data")) return null
            val arr = o.getJSONArray("data")
            val list = (0 until arr.length()).map { i ->
                val n = arr.getJSONObject(i)
                val created = n.optString("createdAt", nowIso())
                Note(n.optString("id", newId()), n.optString("text"), n.optBoolean("done"),
                    created, n.optString("editedAt", created))   // editedAt falls back to createdAt
            }
            o.getLong("updatedAt") to list
        } catch (_: Exception) { null }
    }

    fun notesEnvelope(updatedAt: Long, list: List<Note>, allowDestructive: Boolean = false): String {
        val arr = JSONArray()
        list.forEach { n -> arr.put(JSONObject().put("id", n.id).put("text", n.text).put("done", n.done)
            .put("createdAt", n.createdAt).put("editedAt", n.editedAt)) }
        return envelope(updatedAt, arr, allowDestructive)
    }
}
