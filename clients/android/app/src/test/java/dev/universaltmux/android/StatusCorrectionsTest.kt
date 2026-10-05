package dev.universaltmux.android

import org.junit.Assert.*
import org.junit.Test

class StatusCorrectionsTest {
    private fun status(label: String, time: Double) = AgentCardStatus("analysis", label, "Retained summary", null, time)
    @Test fun nativePathsKeepPendingUntilFreshAcknowledgmentAndSurviveRelaunch() {
        for (lifetime in listOf("tmux-first", "conpty-first")) {
            var disk: String? = null
            var changes = StatusCorrections(disk) { disk = it }
            changes.begin("workspace/session", lifetime, "working", status("idle", 100.0))
            assertEquals("working", changes.merge("workspace/session", lifetime, status("idle", 101.0)).label)
            changes = StatusCorrections(disk) { disk = it }
            assertEquals("working", changes.merge("workspace/session", lifetime, status("idle", 102.0)).label)
            changes.merge("workspace/session", lifetime, status("working", 103.0))
            assertNull(changes.current("workspace/session", lifetime))
            assertEquals("idle", changes.merge("workspace/session", lifetime, status("idle", 104.0)).label)
        }
    }
    @Test fun lateFailureCannotUndoNewChoiceAndReplacementSessionDoesNotInheritIt() {
        val changes = StatusCorrections()
        val old = changes.begin("w/session", "first", "working", status("idle", 100.0))
        val latest = changes.begin("w/session", "first", "stuck", status("idle", 100.0))
        assertFalse(changes.reject("w/session", old))
        assertEquals("stuck", changes.current("w/session", "first")?.label)
        assertNull(changes.current("w/session", "replacement"))
        assertNull(changes.current("other/session", "first"))
        assertTrue(changes.reject("w/session", latest))
        assertNull(changes.current("w/session", "first"))
    }
    @Test fun diskFailureCannotClaimAPendingChange() {
        val changes = StatusCorrections { throw java.io.IOException("disk full") }
        try { changes.begin("w/s", "life", "working", status("idle", 100.0)); fail("must fail") } catch (_: java.io.IOException) { }
        assertNull(changes.current("w/s", "life"))
    }
    @Test fun StaleMatchingLabelDoesNotAcknowledgeNewCorrection() {
        val changes = StatusCorrections()
        changes.begin("w/s", "life", "working", status("working", 100.0))
        changes.merge("w/s", "life", status("working", 100.0))
        assertNotNull(changes.current("w/s", "life"))
    }
    @Test fun receiptAcknowledgesDeliveryEvenIfTheModelReclassifiesBeforeNextPoll() {
        var disk: String? = null
        var changes = StatusCorrections(disk) { disk = it }
        val pending = changes.begin("w/s", "life", "working", status("idle", 100.0))
        changes.accepted("w/s", pending, 1234)
        changes = StatusCorrections(disk)
        assertEquals("idle", changes.merge("w/s", "life", status("idle", 102.0).copy(appliedOverrideTS = 1234)).label)
        assertNull(changes.current("w/s", "life"))
    }
}
