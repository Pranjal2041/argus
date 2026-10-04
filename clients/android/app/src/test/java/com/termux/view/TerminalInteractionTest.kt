package com.termux.view

import android.app.Activity
import android.graphics.Typeface
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import com.termux.terminal.TerminalSession
import dev.universaltmux.android.makeSessionClient
import dev.universaltmux.android.makeViewClient
import java.io.ByteArrayOutputStream
import java.time.Duration
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@LooperMode(LooperMode.Mode.PAUSED)
class TerminalInteractionTest {
    private lateinit var view: TerminalView
    private lateinit var session: TerminalSession
    private lateinit var input: InputConnection
    private val sent = ByteArrayOutputStream()

    @Before fun setUp() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        view = TerminalView(activity, null)
        view.setTerminalViewClient(makeViewClient {})
        view.setTextSize(20)
        view.setTypeface(Typeface.MONOSPACE)
        session = TerminalSession(200, makeSessionClient({ view.onScreenUpdated() }, {}),
            object : TerminalSession.RemoteBridge {
                override fun onInput(data: ByteArray, offset: Int, count: Int) { sent.write(data, offset, count) }
                override fun onResize(columns: Int, rows: Int) {}
            })
        activity.setContentView(view)
        view.attachSession(session)
        view.layout(0, 0, 600, 300)
        view.requestFocus()
        input = view.onCreateInputConnection(EditorInfo())
        sent.reset()
    }

    private fun wire() = sent.toString("UTF-8")
    private fun output(text: String) {
        val bytes = text.toByteArray()
        session.feedOutput(bytes, 0, bytes.size)
    }
    private fun history() { repeat(80) { output("line-${it.toString().padStart(3, '0')}\r\n") } }

    @Test fun composingChangesAreSentInOrderWithoutDuplicateCommit() {
        input.setComposingText("2026", 1)
        input.setComposingText("2027", 1)
        input.commitText("2027", 1)
        assertEquals("2026\u007f7", wire())
        assertEquals("2027", input.getTextBeforeCursor(100, 0).toString())
    }

    @Test fun committedWordCanBeRecomposedWithoutDuplicatingItsPrefix() {
        input.commitText("1234", 1)
        input.setComposingRegion(0, 4)
        input.setComposingText("1235", 1)
        input.finishComposingText()
        assertEquals("1234\u007f5", wire())
    }

    @Test fun deletionThenRecompositionKeepsTheRemainingPrefix() {
        input.setComposingText("1234", 1)
        input.finishComposingText()
        input.deleteSurroundingText(1, 0)
        input.setComposingRegion(0, 3)
        input.setComposingText("1235", 1)
        input.commitText("1235", 1)
        assertEquals("1234\u007f5", wire())
        assertEquals("1235", input.getTextBeforeCursor(100, 0).toString())
    }

    @Test fun selectionReplacementPreservesSuffix() {
        input.commitText("ab123cd", 1)
        input.setSelection(2, 5)
        input.commitText("9", 1)
        assertEquals("ab123cd\u001b[D\u001b[D\u007f\u007f\u007f9", wire())
        assertEquals("ab9", input.getTextBeforeCursor(100, 0).toString())
        assertEquals("cd", input.getTextAfterCursor(100, 0).toString())
    }

    @Test fun forwardDeleteIsNotDropped() {
        input.commitText("1234", 1)
        input.setSelection(2, 2)
        input.deleteSurroundingText(0, 1)
        assertEquals("12", input.getTextBeforeCursor(100, 0).toString())
        assertEquals("4", input.getTextAfterCursor(100, 0).toString())
        assertEquals("1234\u001b[D\u001b[D\u001b[C\u007f", wire())
    }

    @Test fun supplementaryCharactersAreDeletedAsCodePoints() {
        input.commitText("A😀B", 1)
        input.setSelection(3, 3)
        input.deleteSurroundingTextInCodePoints(1, 0)
        assertEquals("A😀B\u001b[D\u007f", wire())
        assertEquals("A", input.getTextBeforeCursor(100, 0).toString())
        assertEquals("B", input.getTextAfterCursor(100, 0).toString())
    }

    @Test fun repeatedIdenticalCommitsAreDistinctKeystrokes() {
        input.commitText("1", 1)
        input.commitText("1", 1)
        assertEquals("11", wire())
    }

    @Test fun newCursorPositionIsHonored() {
        input.commitText("123", 0)
        input.commitText("X", 1)
        assertEquals("123\u001b[D\u001b[D\u001b[DX", wire())
        assertEquals("X", input.getTextBeforeCursor(100, 0).toString())
        assertEquals("123", input.getTextAfterCursor(100, 0).toString())
    }

    @Test fun softKeyboardBackspaceUpdatesComposition() {
        input.setComposingText("1234", 1)
        input.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL))
        input.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL))
        input.setComposingText("1235", 1)
        input.commitText("1235", 1)
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals("1234\u007f5", wire())
    }

    @Test fun outputDoesNotPullAReaderBackToTheBottom() {
        history()
        view.scrollToBufferRow(-20)
        val oldText = view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow)
        output("another line\r\n")
        assertEquals(-21, view.mTopRow)
        assertEquals(oldText, view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow))
    }

    @Test fun repaintWithoutNewLinesKeepsScrollPosition() {
        history()
        view.scrollToBufferRow(-20)
        output("\u001b[1;1Hstatus")
        assertEquals(-20, view.mTopRow)
        view.onScreenUpdated()
        assertEquals(-20, view.mTopRow)
    }

    @Test fun bottomStillFollowsOutputAndHistoryEvictionClampsAtOldestRow() {
        history()
        output("live\r\n")
        assertEquals(0, view.mTopRow)
        view.scrollToBufferRow(-10000)
        repeat(230) { output("more\r\n") }
        assertEquals(-view.mEmulator.screen.activeTranscriptRows, view.mTopRow)
    }

    @Test fun touchingDuringAFlingStopsTheOldAnimation() {
        history()
        view.mScroller.startScroll(0, -20, 0, -20, 1000)
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_DOWN, 100f, 100f, 0)
        try { view.onTouchEvent(event) } finally { event.recycle() }
        assertTrue(view.mScroller.isFinished)
    }

    @Test fun batchEditsReconcileOnceAtTheFinalSelection() {
        input.beginBatchEdit()
        input.setComposingText("12", 1)
        input.setComposingText("123", 1)
        input.commitText("123", 1)
        assertEquals("", wire())
        input.endBatchEdit()
        assertEquals("123", wire())
    }

    @Test fun deletionOutsideTheKnownInputStillReachesTheTerminal() {
        input.deleteSurroundingText(2, 1)
        assertEquals("\u007f\u007f\u001b[3~", wire())
    }

    @Test fun supplementaryCompositionReplacementDoesNotSplitSurrogates() {
        input.setComposingText("😀", 1)
        input.setComposingText("😁", 1)
        assertEquals("😀\u007f😁", wire())
    }

    @Test fun compositionWithSharedSuffixDoesNotRetypeTheSuffix() {
        input.setComposingText("abc123", 1)
        input.setComposingText("axc123", 1)
        assertEquals("abc123" + "\u001b[D".repeat(4) + "\u007fx" + "\u001b[C".repeat(4), wire())
    }

    @Test fun voiceTextAndNewlineAreDeliveredOnceAndClearOldCommandContext() {
        input.setComposingText("hello world", 1)
        input.commitText("hello world", 1)
        input.commitText("\n", 1)
        input.commitText("next", 1)
        assertEquals("hello world\rnext", wire())
        assertEquals("next", input.getTextBeforeCursor(100, 0).toString())
    }

    @Test fun rawAccessoryInputInvalidatesCompositionAndClosedConnectionsCannotWrite() {
        input.setComposingText("123", 1)
        view.onExternalInput()
        input.setComposingText("4", 1)
        assertEquals("1234", wire())
        input.closeConnection()
        assertFalse(input.commitText("stale", 1))
        assertEquals("1234", wire())
    }

    @Test fun typingReturnsToTheLiveScreen() {
        history()
        view.scrollToBufferRow(-10)
        input.commitText("x", 1)
        assertEquals(0, view.mTopRow)
    }

    @Test fun onlyRequestedMouseReportingCanRouteScrollingToTheApplication() {
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_MOVE, 100f, 100f, 0)
        try {
            output("\u001b[?1000h\u001b[?1006h")
            view.doScroll(event, -2)
            assertTrue(wire().startsWith("\u001b[<64;"))
            assertEquals(0, view.mTopRow)
            output("\u001b[?1000l\u001b[?1006l\u001b[?1049h")
            sent.reset()
            view.doScroll(event, -2)
            assertEquals("A full-screen buffer must not turn a swipe into arrow keys", "", wire())
        } finally { event.recycle() }
    }

    @Test fun alternateScreenWithoutMouseTrackingNeverFlingsThroughPromptHistory() {
        output("\u001b[?1049h")
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_UP, 100f, 100f, 0)
        view.mGestureRecognizer.mListener.onFling(event, 0f, 1600f)
        event.recycle() // The animation must own a copy, not this recycled event.
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals("", wire())
    }

    @Test fun aScreenModeChangeCancelsAnOldFling() {
        history()
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_UP, 100f, 100f, 0)
        view.mGestureRecognizer.mListener.onFling(event, 0f, 1600f)
        event.recycle()
        output("\u001b[?1049h")
        shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
        assertEquals("", wire())
        assertTrue(view.mScroller.isFinished)
    }

    @Test fun subRowDragsAreVisibleAndSurviveFingerLiftAndOutput() {
        history()
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_MOVE, 100f, 100f, 0)
        try {
            view.doScrollPixels(event, -3.5f)
            assertEquals(-3.5f, view.scrollPositionPixels(), 0.01f)
            assertTrue(view.mScrollOffsetY > 0)
            view.mGestureRecognizer.mListener.onUp(event)
            assertEquals(-3.5f, view.scrollPositionPixels(), 0.01f)
            val offset = view.mScrollOffsetY
            output("new output\r\n")
            assertEquals(offset, view.mScrollOffsetY, 0.01f)
            assertEquals(-3.5f - view.mRenderer.mFontLineSpacing, view.scrollPositionPixels(), 0.01f)
            view.doScrollPixels(event, 100000f)
            assertEquals(0f, view.scrollPositionPixels(), 0f)
        } finally { event.recycle() }
    }

    @Test fun flingUsesPixelPositionsAndTypingCancelsItsMomentum() {
        history()
        view.scrollToBufferRow(-20)
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_UP, 100f, 100f, 0)
        try {
            view.mGestureRecognizer.mListener.onFling(event, 0f, 1200f)
            assertEquals(-20 * view.mRenderer.mFontLineSpacing, view.mScroller.startY)
            input.commitText("x", 1)
            shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(1))
            assertEquals(0f, view.scrollPositionPixels(), 0f)
            assertTrue(view.mScroller.isFinished)
        } finally { event.recycle() }
    }

    @Test fun fullScreenRoundTripRestoresThePrimaryHistoryAnchor() {
        history()
        view.scrollToBufferRow(-20)
        val before = view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow)
        output("\u001b[?1049hfullscreen application")
        assertEquals(0, view.mTopRow)
        output("\u001b[?1049l")
        assertEquals(-20, view.mTopRow)
        assertEquals(before, view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow))
    }

    @Test fun keyboardResizeDoesNotDiscardTheHistoryAnchor() {
        history()
        view.scrollToBufferRow(-10)
        val before = view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow)
        view.layout(0, 0, 600, 200)
        assertTrue(view.mTopRow < 0)
        assertEquals(before, view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow))
    }

    @Test fun allMotionMouseModeIsNotMistakenForLocalHistory() {
        output("\u001b[?1049h\u001b[?1003h\u001b[?1006h")
        assertTrue(view.mEmulator.isMouseTrackingActive)
        val event = MotionEvent.obtain(1, 1, MotionEvent.ACTION_MOVE, 100f, 100f, 0)
        try { view.doScroll(event, -1) } finally { event.recycle() }
        assertTrue(wire().startsWith("\u001b[<64;"))
        output("\u001b[?1003l")
        assertFalse(view.mEmulator.isMouseTrackingActive)
    }

    @Test fun authoritativeRepaintDoesNotCountItsEntireHistoryAsNewOutput() {
        history()
        view.scrollToBufferRow(-20)
        val before = view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow)
        view.beginScreenSnapshot()
        output("\u001b[2J\u001b[3J\u001b[H")
        history()
        output("one genuinely new line\r\n")
        view.endScreenSnapshot()
        assertEquals(-21, view.mTopRow)
        assertEquals(before, view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow))
        output("another genuinely new line\r\n")
        assertEquals(-22, view.mTopRow)
    }

    @Test fun aReaderAtTheBottomStillFollowsAfterARepaint() {
        history()
        view.beginScreenSnapshot()
        output("\u001b[2J\u001b[3J\u001b[H")
        history()
        view.endScreenSnapshot()
        assertEquals(0, view.mTopRow)
        assertEquals(0f, view.mScrollOffsetY, 0f)
    }
}
