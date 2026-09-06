package dev.universaltmux.android

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class WorkspaceMergeTest {
    @Test fun reviewDocumentsAreValidatedWithoutLossBeforeCommit() {
        val note = Note("12345678-1234-1234-1234-123456789abc", "retained", false, "2026-09-06T12:00:00Z", "2026-09-06T12:00:00Z")
        val valid = org.json.JSONObject(UserDataJson.notesEnvelope(1L, listOf(note))).getJSONArray("data")
        UserDataJson.validateWorkspace("notes", valid)
        val duplicate = JSONArray(valid.toString()).put(valid.getJSONObject(0))
        assertThrows(IllegalArgumentException::class.java) { UserDataJson.validateWorkspace("notes", duplicate) }
        valid.getJSONObject(0).put("unknownFutureField", "must not silently discard")
        assertThrows(IllegalArgumentException::class.java) { UserDataJson.validateWorkspace("notes", valid) }
    }
    @Test fun independentRecordsAndFieldsMerge() {
        val base = JSONArray("""[{"id":"a","text":"old","done":false}]""")
        val local = JSONArray("""[{"id":"a","text":"new","done":false}]""")
        val remote = JSONArray("""[{"id":"a","text":"old","done":true},{"id":"b","text":"other"}]""")
        val merged = WorkspaceMerge.merge(base,local,remote) as JSONArray
        assertEquals(2,merged.length()); assertEquals("new", merged.getJSONObject(0).getString("text")); assertTrue(merged.getJSONObject(0).getBoolean("done"))
    }
    @Test fun nestedTodoItemsMerge() {
        val base = JSONArray("""[{"id":"board","items":[{"id":"x","done":false}]}]""")
        val local = JSONArray("""[{"id":"board","items":[{"id":"x","done":false},{"id":"y","done":false}]}]""")
        val remote = JSONArray("""[{"id":"board","items":[{"id":"x","done":true}]}]""")
        val merged = WorkspaceMerge.merge(base,local,remote) as JSONArray
        assertEquals(2, merged.getJSONObject(0).getJSONArray("items").length())
    }
    @Test fun conflictingEditAndDeleteNeverSilentlyWin() {
        val base = JSONArray("""[{"id":"a","text":"old"}]""")
        val local = JSONArray("""[{"id":"a","text":"local"}]""")
        val remote = JSONArray("""[{"id":"a","text":"remote"}]""")
        assertThrows(IllegalStateException::class.java) { WorkspaceMerge.merge(base,local,remote) }
        assertThrows(IllegalStateException::class.java) { WorkspaceMerge.merge(base,JSONArray(),remote) }
        assertTrue(WorkspaceMerge.equal(WorkspaceMerge.merge(base,JSONArray(),base), JSONArray()))
    }
}
