package dev.universaltmux.android

import org.junit.Assert.assertEquals
import org.junit.Test

class LabLifecycleTest {
    @Test
    fun stoppedIsLifecycleAndArchiveRemainsIndependentViewState() {
        val stopped = LabRunSummary(
            id = "R2", status = "stopped", stoppedAt = "2026-07-16T03:00:00Z",
            stopReason = "wrapper disappeared; scheduler confirms no job", archived = true,
            latestAt = "2026-07-15T22:00:00Z",
        )

        assertEquals("stopped", labRunPhase(stopped))
        assertEquals("2026-07-16T03:00:00Z", labRunActivityAt(stopped))
    }
}
