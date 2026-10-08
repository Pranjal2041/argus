package dev.universaltmux.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.time.ZoneId

class WorkspaceContractTest {
    @Test fun paginationKeepsLinesAndHeadingsWhole() {
        val cuts = pdfPageCuts(480f, 100f, listOf(90f to 115f, 190f to 210f, 300f to 420f))
        assertEquals(0f, cuts.first()); assertEquals(480f, cuts.last())
        assertTrue(cuts.zipWithNext().all { (start, end) -> end > start && end - start <= 100f })
        assertFalse(cuts.any { it > 90 && it < 115 })
        assertFalse(cuts.any { it > 190 && it < 210 })
    }
    private fun fixture(name: String) = JSONObject(javaClass.classLoader!!.getResourceAsStream(name)!!.bufferedReader().use { it.readText() })
    @Test fun authoredSourceUsesTheSameArchiveContractAsSwift() {
        val expected = fixture("render-source-v1.json")
        val document = expected.getJSONObject("document")
        val actual = renderSourceArchive(RenderContent(1, document.getString("source"), document.getString("sourceOrigin"), terminalText = "Terminal fallback"), 14)
        actual.getJSONObject("document").put("id", document.getString("id"))
        assertTrue(expected.similar(actual))
    }
    @Test fun samePortableLocatorFixturesAsSwift() {
        val root = fixture("locators-v1.json")
        root.getJSONArray("websites").objects().forEach { row -> assertEquals(row.toString(), row.getBoolean("valid"), runCatching { WorkspaceLocators.website(row.getString("url")) }.isSuccess) }
        root.getJSONArray("services").objects().forEach { row -> assertEquals(row.toString(), row.getBoolean("valid"), runCatching { WorkspaceLocators.service(row.getString("brokerID"), row.getInt("port"), row.getString("path")) }.isSuccess) }
    }
    @Test fun sharedWireFixturePreservesUnknownFieldsAndLifetimes() {
        val root = fixture("replica-v1.json")
        val disk = object : WorkspacePersistence { override fun read(workspaceID: String) = root.toString(); override fun write(workspaceID: String, document: String) {} }
        val replica = WorkspaceRepository(disk); replica.bind("fixture-workspace")
        assertTrue(replica.loaded)
        assertEquals(12, replica.data("session-read", "fixture-broker/lifetime-1")!!.getInt("seenRevision"))
        assertNull(replica.data("session-read", "fixture-broker/lifetime-2"))
        val dashboard = replica.collection("dashboards").single()
        val next = JSONObject(dashboard.data.toString()).put("name", "Renamed on phone")
        replica.enqueue("dashboards", dashboard.id, next)
        assertTrue(replica.data("dashboards", dashboard.id)!!.getJSONObject("futureField").getBoolean("keep"))
    }
    @Test fun draftsRecoverExactBaseAndAreScopedByHostAndPath() {
        val root = Files.createTempDirectory("editor-drafts").toFile()
        try {
            val store = EditorDraftStore(root)
            val draft = EditorDraft("sha256:revision", "original", "edited\nαβ")
            store.save("host-one", "/project/a.kt", draft)
            assertEquals(draft, EditorDraftStore(root).read("host-one", "/project/a.kt"))
            assertNull(store.read("host-two", "/project/a.kt")); assertNull(store.read("host-one", "/project/b.kt"))
            store.remove("host-one", "/project/a.kt"); assertNull(store.read("host-one", "/project/a.kt"))
        } finally { root.deleteRecursively() }
    }
    @Test fun dayOnlyPlannerDeadlineFollowsLocalCalendarAcrossDST() {
        val zone = ZoneId.of("America/New_York")
        val plan = PlannerCommitment(deadline = "2026-11-01T05:00:00Z", hasExactTime = false)
        assertEquals("2026-11-02T04:59:59Z", plan.effectiveDeadline(zone).toString())
        assertEquals("2026-11-01T05:00:00Z", plan.copy(hasExactTime = true).effectiveDeadline(zone).toString())
    }
    @Test fun warningDismissalIsImmediateButDoesNotHideEscalationOrRenewal() {
        val warning = JSONObject().put("id", "q").put("cycle", "c1").put("critical", false)
        val dismissals = JSONObject().put("q", JSONObject().put("cycle", "c1").put("critical", false).put("expiresAt", 500))
        assertFalse(usageWarningVisible(warning, dismissals, 100))
        assertTrue(usageWarningVisible(warning, dismissals, 600))
        assertTrue(usageWarningVisible(JSONObject(warning.toString()).put("critical", true), dismissals, 100))
        assertTrue(usageWarningVisible(JSONObject(warning.toString()).put("cycle", "c2"), dismissals, 100))
    }
}
