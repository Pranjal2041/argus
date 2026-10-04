package dev.universaltmux.android

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class WorkspaceRepositoryTest {
    private class Disk : WorkspacePersistence {
        val files = mutableMapOf<String, String>()
        var fail = false
        override fun read(workspaceID: String) = files[workspaceID]
        override fun write(workspaceID: String, document: String) {
            if (fail) throw IOException("disk full")
            files[workspaceID] = document
        }
    }
    private class Server : WorkspaceTransport {
        var revision = 0L
        val records = mutableMapOf<String, WorkspaceRecord>()
        val receipts = mutableMapOf<String, JSONObject>()
        var fail = false
        var loseAcknowledgment = false
        var mutations = 0
        override fun get(broker: Broker, path: String): JSONObject {
            if (fail) throw IOException("offline")
            return when {
                path == "/workspace/info" -> JSONObject().put("protocol", 1).put("workspaceID", "workspace").put("enabled", true)
                path == "/workspace/snapshot" -> snapshot()
                else -> JSONObject().put("cursor", revision).put("records", JSONArray(records.values.map { it.json() })).put("more", false)
            }
        }
        fun snapshot() = JSONObject().put("workspaceID", "workspace").put("cursor", revision).put("records", JSONArray(records.values.map { it.json() }))
        override fun post(broker: Broker, path: String, body: JSONObject): JSONObject {
            if (fail) throw IOException("offline")
            val id = body.getString("mutationID")
            receipts[id]?.let { return JSONObject(it.toString()) }
            val key = body.getString("collection") + "\u0000" + body.getString("id")
            val current = records[key]
            if (body.getLong("baseRevision") != (current?.revision ?: 0L)) throw WorkspaceHTTPException(409,
                JSONObject().put("current", (current ?: WorkspaceRecord(body.getString("collection"), body.getString("id"), 0, null)).json()))
            revision++; mutations++
            val record = WorkspaceRecord(body.getString("collection"), body.getString("id"), revision, body.optJSONObject("data"), body.optBoolean("delete"))
            records[key] = record
            val receipt = JSONObject().put("mutationID", id).put("record", record.json()).put("cursor", revision)
            receipts[id] = receipt
            if (loseAcknowledgment) { loseAcknowledgment = false; throw IOException("connection lost after commit") }
            return receipt
        }
    }
    private val broker = Broker("fixture", "http", "fixture")
    private fun repository(disk: Disk, server: Server) = WorkspaceRepository(disk, server).also { it.bind("workspace") }

    @Test fun lostAcknowledgmentRetriesSameMutationAfterRelaunch() = runBlocking {
        val disk = Disk(); val server = Server(); var repo = repository(disk, server)
        repo.synchronize(broker)
        repo.enqueue("session-backlog", "broker/lineage", JSONObject().put("value", true))
        server.loseAcknowledgment = true; repo.synchronize(broker, force = true)
        assertEquals(1, repo.pending.size); assertEquals(1, server.mutations)
        repo = repository(disk, server); repo.synchronize(broker, force = true)
        assertTrue(repo.pending.isEmpty()); assertEquals(1, server.mutations)
        assertTrue(repo.data("session-backlog", "broker/lineage")!!.getBoolean("value"))
    }

    @Test fun offlineRefreshPreservesCachedAndPendingData() = runBlocking {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.synchronize(broker); repo.enqueue("notebooks", "n", JSONObject().put("path", "/project/a.ipynb"))
        server.fail = true; repo.synchronize(broker, force = true)
        assertEquals("/project/a.ipynb", repo.data("notebooks", "n")!!.getString("path"))
        assertEquals(1, repo.pending.size); assertNotNull(repo.issue)
        val relaunched = repository(disk, server)
        assertEquals(1, relaunched.pending.size)
    }

    @Test fun conflictingEditsRetainBothCopiesForReview() = runBlocking {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.synchronize(broker); repo.enqueue("dashboards", "d", JSONObject().put("name", "phone"))
        server.post(broker, "", JSONObject().put("mutationID", "mac").put("collection", "dashboards").put("id", "d")
            .put("baseRevision", 0).put("data", JSONObject().put("name", "mac")))
        repo.synchronize(broker, force = true)
        assertEquals("phone", repo.data("dashboards", "d")!!.getString("name"))
        assertEquals("mac", repo.record("dashboards", "d")!!.data!!.getString("name"))
        assertTrue(repo.pending.single().has("conflict"))
        repo.resolve(repo.pending.single().getString("mutationID"), keepLocal = false)
        assertEquals("mac", repo.data("dashboards", "d")!!.getString("name"))
    }

    @Test fun diskFailureDoesNotAcknowledgeAnUnsavedEdit() = runBlocking {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.synchronize(broker); disk.fail = true
        try { repo.enqueue("dashboards", "d", JSONObject().put("name", "lost")); fail("must fail") } catch (_: IOException) { }
        assertTrue(repo.pending.isEmpty()); assertNull(repo.data("dashboards", "d"))
    }

    @Test fun staleActivityAcknowledgmentCannotClearANewerRevision() = runBlocking {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.synchronize(broker); repo.enqueue("session-read", "lifetime", JSONObject().put("seenRevision", 8))
        server.post(broker, "", JSONObject().put("mutationID", "other").put("collection", "session-read").put("id", "lifetime")
            .put("baseRevision", 0).put("data", JSONObject().put("seenRevision", 12)))
        repo.synchronize(broker, force = true)
        assertEquals(12L, repo.data("session-read", "lifetime")!!.getLong("seenRevision"))
        assertTrue(repo.pending.isEmpty())
    }

    @Test fun lateChangeDoesNotReplaceNewerRecord() {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.acceptSnapshot(server.snapshot())
        fun page(rev: Long, cursor: Long, name: String) = JSONObject().put("cursor", cursor).put("records", JSONArray()
            .put(WorkspaceRecord("dashboards", "d", rev, JSONObject().put("name", name)).json()))
        repo.acceptChanges(page(7, 7, "new")); repo.acceptChanges(page(3, 8, "old"))
        assertEquals("new", repo.data("dashboards", "d")!!.getString("name"))
    }

    @Test fun keepLocalConflictDoesNotMoveEarlierEditAfterLaterEdits() = runBlocking {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.synchronize(broker)
        repo.enqueue("dashboards", "d", JSONObject().put("name", "first edit"))
        repo.enqueue("dashboards", "d", JSONObject().put("name", "later edit"))
        server.post(broker, "", JSONObject().put("mutationID", "remote").put("collection", "dashboards").put("id", "d")
            .put("baseRevision", 0).put("data", JSONObject().put("name", "remote edit")))
        repo.synchronize(broker, force = true)
        repo.resolve(repo.pending.first { it.has("conflict") }.getString("mutationID"), keepLocal = true)
        assertEquals("later edit", repo.pending.last().getJSONObject("data").getString("name"))
        repo.synchronize(broker, force = true)
        repo.synchronize(broker, force = true) // Rebased successor commits on the next sync.
        assertTrue(repo.pending.isEmpty())
        assertEquals("later edit", repo.data("dashboards", "d")!!.getString("name"))
    }

    @Test fun workspaceSwitchSeparatesPendingChangesAndRestoresOriginalCache() = runBlocking {
        val disk = Disk(); val server = Server(); val repo = repository(disk, server)
        repo.synchronize(broker); repo.enqueue("dashboards", "d", JSONObject().put("name", "A only"))
        repo.bind("other-workspace")
        assertNull(repo.data("dashboards", "d")); assertTrue(repo.pending.isEmpty())
        repo.bind("workspace")
        assertEquals("A only", repo.data("dashboards", "d")!!.getString("name")); assertEquals(1, repo.pending.size)
    }
}
