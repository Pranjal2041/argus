package dev.universaltmux.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException

data class WorkspaceRecord(val collection: String, val id: String, val revision: Long,
                           val data: JSONObject?, val deleted: Boolean = false, val updatedAt: Long = 0) {
    val key get() = "$collection\u0000$id"
    fun json() = JSONObject().put("collection", collection).put("id", id).put("revision", revision)
        .put("data", data).put("deleted", deleted).put("updatedAt", updatedAt)
    companion object {
        fun parse(o: JSONObject) = WorkspaceRecord(o.getString("collection"), o.getString("id"),
            o.getLong("revision"), o.optJSONObject("data"), o.optBoolean("deleted"), o.optLong("updatedAt"))
    }
}

interface WorkspacePersistence {
    fun read(workspaceID: String): String?
    /** Must atomically replace the complete cache + outbox or throw. */
    fun write(workspaceID: String, document: String)
}

class WorkspaceHTTPException(val status: Int, val document: JSONObject) : IOException(
    document.optString("message", document.optString("error", "Workspace request failed (HTTP $status)")))

interface WorkspaceTransport {
    fun get(broker: Broker, path: String): JSONObject
    fun post(broker: Broker, path: String, body: JSONObject): JSONObject
}

object WorkspaceNet : WorkspaceTransport {
    override fun get(broker: Broker, path: String): JSONObject = call(Request.Builder().url(broker.httpBase + path).build())
    override fun post(broker: Broker, path: String, body: JSONObject): JSONObject = call(Request.Builder()
        .url(broker.httpBase + path).post(body.toString().toRequestBody("application/json".toMediaType())).build())
    private fun call(request: Request): JSONObject = Net.client.newCall(request).execute().use { response ->
        val text = response.body?.string() ?: throw IOException("Empty workspace response")
        val body = runCatching { JSONObject(text) }.getOrNull()
        if (!response.isSuccessful) throw WorkspaceHTTPException(response.code, body ?: JSONObject().put("error", "HTTP ${response.code}"))
        body ?: throw IOException("Invalid workspace response")
    }
}

/** The durable replica is independent of screens. Cache, cursor and pending writes
 * are saved together; a failed request never replaces authoritative data. */
class WorkspaceRepository(private val persistence: WorkspacePersistence,
                          private val transport: WorkspaceTransport = WorkspaceNet) {
    var workspaceID by mutableStateOf(""); private set
    var records by mutableStateOf<List<WorkspaceRecord>>(emptyList()); private set
    var pending by mutableStateOf<List<JSONObject>>(emptyList()); private set
    var issue by mutableStateOf<String?>(null); private set
    var syncing by mutableStateOf(false); private set
    var loaded by mutableStateOf(false); private set
    var lastSyncedAt by mutableStateOf(0L); private set
    private var state = JSONObject()
    private var storageFailure = false
    private var retryAt = 0L
    var onChange: (() -> Unit)? = null

    fun bind(id: String) {
        if (id == workspaceID) return
        check(!syncing) { "Wait for the current workspace sync to finish." }
        workspaceID = id; records = emptyList(); pending = emptyList(); loaded = false
        state = JSONObject(); issue = null; storageFailure = false; retryAt = 0
        try {
            val saved = persistence.read(id)
            if (saved != null) {
                val document = JSONObject(saved)
                check(document.getString("workspaceID") == id) { "Workspace cache identity mismatch" }
                install(document)
            }
        } catch (_: Exception) {
            storageFailure = true; issue = "Workspace cache could not be read. The saved copy has been retained."
        }
    }

    fun record(collection: String, id: String): WorkspaceRecord? = records.firstOrNull { it.collection == collection && it.id == id }

    fun data(collection: String, id: String): JSONObject? {
        val intent = pending.lastOrNull { it.getString("collection") == collection && it.getString("id") == id }
        if (intent != null) return if (intent.optBoolean("delete")) null else intent.optJSONObject("data")
        return record(collection, id)?.takeUnless { it.deleted }?.data
    }

    fun collection(name: String): List<WorkspaceRecord> {
        val byID = records.filter { it.collection == name }.associateBy { it.id }.toMutableMap()
        pending.filter { it.getString("collection") == name }.forEach { p ->
            byID[p.getString("id")] = WorkspaceRecord(name, p.getString("id"), p.getLong("baseRevision"), p.optJSONObject("data"), p.optBoolean("delete"))
        }
        return byID.values.filterNot { it.deleted }.sortedBy { it.id }
    }

    fun enqueue(collection: String, id: String, data: JSONObject?, delete: Boolean = false): String {
        check(workspaceID.isNotEmpty() && loaded && !storageFailure) { "Connect this workspace before editing shared state." }
        val base = this.data(collection, id)
        val operation = JSONObject().put("mutationID", newId()).put("collection", collection).put("id", id)
            .put("baseRevision", record(collection, id)?.revision ?: 0L)
            .put("baseData", base?.let { JSONObject(it.toString()) })
            .put("data", data?.let { JSONObject(it.toString()) }).put("delete", delete)
        val next = copyState()
        next.getJSONArray("pending").put(operation)
        commit(next)
        return operation.getString("mutationID")
    }

    fun resolve(mutationID: String, keepLocal: Boolean) {
        val operation = pending.firstOrNull { it.getString("mutationID") == mutationID } ?: return
        check(operation.has("conflict")) { "The operation has no conflict to resolve." }
        val current = record(operation.getString("collection"), operation.getString("id"))
        val next = copyState()
        val list = pending.map { JSONObject(it.toString()) }.toMutableList()
        val index = list.indexOfFirst { it.getString("mutationID") == mutationID }
        if (keepLocal) {
            list[index] = JSONObject(operation.toString()).removeConflict().put("mutationID", newId())
                .put("baseRevision", current?.revision ?: 0L).put("baseData", current?.data)
        } else list.removeAt(index)
        next.put("pending", JSONArray(list)); commit(next)
    }

    suspend fun synchronize(broker: Broker, force: Boolean = false) {
        if (syncing || workspaceID.isEmpty() || storageFailure || (!force && System.currentTimeMillis() < retryAt)) return
        syncing = true
        val boundID = workspaceID
        try {
            val info = withContext(Dispatchers.IO) { transport.get(broker, "/workspace/info") }
            check(info.getInt("protocol") == 1 && info.getString("workspaceID") == boundID && info.getBoolean("enabled")) {
                "The selected host is not this workspace. Choose its original host."
            }
            if (!loaded) {
                acceptSnapshot(withContext(Dispatchers.IO) { transport.get(broker, "/workspace/snapshot") })
            } else {
                try {
                    for (pageNumber in 0 until 10) {
                        val page = withContext(Dispatchers.IO) { transport.get(broker, "/workspace/changes?after=${state.optLong("cursor")}&limit=500") }
                        acceptChanges(page)
                        if (!page.optBoolean("more")) break
                    }
                } catch (e: WorkspaceHTTPException) {
                    if (e.status != 410) throw e
                    acceptSnapshot(withContext(Dispatchers.IO) { transport.get(broker, "/workspace/snapshot") })
                }
            }
            val blockedKeys = mutableSetOf<String>()
            for (original in pending.toList()) {
                val key = original.getString("collection") + "\u0000" + original.getString("id")
                if (original.has("conflict") || key in blockedKeys) { blockedKeys.add(key); continue }
                val operation = JSONObject(original.toString()).apply { remove("baseData"); remove("conflict") }
                try {
                    val result = withContext(Dispatchers.IO) { transport.post(broker, "/workspace/mutate", operation) }
                    check(result.getString("mutationID") == operation.getString("mutationID")) { "Mismatched mutation receipt" }
                    val record = WorkspaceRecord.parse(result.getJSONObject("record"))
                    check(record.key == key && record.revision > operation.getLong("baseRevision")) { "The mutation receipt does not identify the committed record." }
                    val next = copyState()
                    mergeRecord(next, record)
                    removePending(next, operation.getString("mutationID"))
                    // A receipt's cursor is NOT our change-stream cursor. Other
                    // clients may have committed intervening events we must read.
                    commit(next)
                } catch (e: WorkspaceHTTPException) {
                    if (e.status != 409 || !e.document.has("current")) throw e
                    reconcileConflict(original, WorkspaceRecord.parse(e.document.getJSONObject("current")))
                    blockedKeys.add(key)
                }
            }
            lastSyncedAt = System.currentTimeMillis(); issue = null; retryAt = 0
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            issue = e.message ?: "Workspace unavailable; local data and pending changes are retained."
            retryAt = System.currentTimeMillis() + 15_000
        } finally { syncing = false; onChange?.invoke() }
    }

    internal fun acceptSnapshot(snapshot: JSONObject) {
        check(snapshot.getString("workspaceID") == workspaceID) { "Workspace snapshot identity mismatch" }
        val cursor = snapshot.getLong("cursor")
        check(cursor >= state.optLong("cursor")) { "Workspace revision moved backwards. Existing data is retained." }
        val rows = snapshot.getJSONArray("records")
        val incoming = (0 until rows.length()).map { WorkspaceRecord.parse(rows.getJSONObject(it)) }
        check(incoming.map { it.key }.distinct().size == incoming.size && incoming.all { it.revision in 1..cursor }) { "Workspace snapshot records are inconsistent." }
        val next = copyState().put("records", snapshot.getJSONArray("records")).put("cursor", cursor).put("loaded", true)
        // A delayed snapshot cannot supersede a newer, already acknowledged write.
        records.filter { it.revision > cursor }.forEach { mergeRecord(next, it) }
        commit(next)
    }

    internal fun acceptChanges(page: JSONObject) {
        check(page.getLong("cursor") >= state.optLong("cursor")) { "Out-of-order workspace change page" }
        val next = copyState()
        val items = page.getJSONArray("records")
        for (i in 0 until items.length()) {
            val record = WorkspaceRecord.parse(items.getJSONObject(i))
            check(record.revision in 1..page.getLong("cursor")) { "Workspace change records are inconsistent." }
            mergeRecord(next, record)
        }
        next.put("cursor", page.getLong("cursor")); commit(next)
    }

    private fun reconcileConflict(operation: JSONObject, current: WorkspaceRecord) {
        val next = copyState(); mergeRecord(next, current)
        val local = if (operation.optBoolean("delete")) null else operation.optJSONObject("data")
        val remote = current.takeUnless { it.deleted }?.data
        val copy = JSONObject(operation.toString())
        try {
            val merged = if (operation.getString("collection") == "session-read" && local != null && remote != null) {
                JSONObject().put("seenRevision", maxOf(local.getLong("seenRevision"), remote.getLong("seenRevision")))
            } else WorkspaceMerge.merge(operation.optJSONObject("baseData"), local, remote)
            removePending(next, operation.getString("mutationID"))
            if (!WorkspaceMerge.equal(merged, remote)) {
                copy.put("mutationID", newId()).put("baseRevision", current.revision).put("baseData", remote)
                    .put("data", merged).put("delete", merged == null)
                // Preserve ordering ahead of subsequent edits to this record.
                val list = next.getJSONArray("pending")
                next.put("pending", JSONArray().put(copy).also { result -> for (i in 0 until list.length()) result.put(list.get(i)) })
            }
        } catch (_: IllegalStateException) {
            copy.put("conflict", "Concurrent edits need review. Both copies are retained.")
            replacePending(next, copy)
        }
        commit(next)
    }

    private fun copyState(): JSONObject = JSONObject(state.toString()).apply {
        put("workspaceID", workspaceID)
        if (!has("records")) put("records", JSONArray())
        if (!has("pending")) put("pending", JSONArray())
    }

    private fun mergeRecord(document: JSONObject, incoming: WorkspaceRecord) {
        val array = document.getJSONArray("records")
        for (i in 0 until array.length()) {
            val old = WorkspaceRecord.parse(array.getJSONObject(i))
            if (old.key == incoming.key) { if (incoming.revision >= old.revision) array.put(i, incoming.json()); return }
        }
        array.put(incoming.json())
    }

    private fun removePending(document: JSONObject, id: String) {
        val items = document.getJSONArray("pending")
        document.put("pending", JSONArray((0 until items.length()).map { items.getJSONObject(it) }.filterNot { it.getString("mutationID") == id }))
    }
    private fun replacePending(document: JSONObject, operation: JSONObject) {
        val array = document.getJSONArray("pending")
        for (i in 0 until array.length()) if (array.getJSONObject(i).getString("mutationID") == operation.getString("mutationID")) { array.put(i, operation); return }
    }
    private fun JSONObject.removeConflict(): JSONObject { remove("conflict"); return this }

    private fun commit(next: JSONObject) {
        check(!storageFailure) { "Workspace storage requires repair; saved data has not been replaced." }
        persistence.write(workspaceID, next.toString())
        install(next)
        onChange?.invoke()
    }
    private fun install(next: JSONObject) {
        val array = next.getJSONArray("records")
        val nextRecords = (0 until array.length()).map { WorkspaceRecord.parse(array.getJSONObject(it)) }
        val queue = next.getJSONArray("pending")
        val nextPending = (0 until queue.length()).map { queue.getJSONObject(it) }
        state = next; records = nextRecords; pending = nextPending; loaded = next.optBoolean("loaded")
    }
}
