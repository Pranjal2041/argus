package dev.universaltmux.android

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UserDataJsonTest {
    @Test
    fun destructiveIntentIsOnlySerializedWhenExplicit() {
        val workflows = listOf(Workflow(name = "kept"))
        assertFalse(JSONObject(UserDataJson.workflowsEnvelope(1, workflows)).has("allowDestructive"))
        assertTrue(JSONObject(UserDataJson.workflowsEnvelope(2, emptyList(), true))
            .getBoolean("allowDestructive"))

        val boards = listOf(TodoBoard(isMisc = true))
        assertFalse(JSONObject(UserDataJson.todosEnvelope(1, boards)).has("allowDestructive"))
        assertTrue(JSONObject(UserDataJson.todosEnvelope(2, boards, true))
            .getBoolean("allowDestructive"))

        assertFalse(JSONObject(UserDataJson.notesEnvelope(1, emptyList())).has("allowDestructive"))
        assertTrue(JSONObject(UserDataJson.notesEnvelope(2, emptyList(), true))
            .getBoolean("allowDestructive"))
    }
}
