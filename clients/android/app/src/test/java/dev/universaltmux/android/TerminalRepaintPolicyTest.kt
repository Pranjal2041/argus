package dev.universaltmux.android

import org.junit.Assert.*
import org.junit.Test

class TerminalRepaintPolicyTest {
    @Test fun legacySizeRepliesCannotCreateAnEndlessSnapshotLoop() {
        val state = TerminalRepaintPolicy()
        assertTrue(state.onSize(80, 24))
        repeat(20) { assertFalse(state.onSize(80, 24)) }
        assertTrue(state.onSize(80, 16))
        assertFalse(state.onSize(80, 16))
    }

    @Test fun orderedSnapshotAlreadyContainsItsRepaintAtTheAuthoritativeSize() {
        val state = TerminalRepaintPolicy()
        state.inSnapshot = true
        assertFalse(state.onSize(80, 24))
        state.inSnapshot = false
        assertFalse(state.onSize(80, 24))
        assertTrue(state.onSize(90, 30))
        state.inSnapshot = true
        assertFalse(state.onSize(90, 30))
        state.reset()
        assertTrue(state.onSize(90, 30))
    }
}
