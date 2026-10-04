package dev.universaltmux.android

import android.app.Activity
import android.graphics.Typeface
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import java.io.ByteArrayOutputStream
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
class TerminalHistoryViewTest {
    private lateinit var terminal: TerminalView
    private lateinit var host: TerminalHistoryView
    private lateinit var session: TerminalSession
    private val sent = ByteArrayOutputStream()
    private val requests = mutableListOf<(TerminalHistoryText?) -> Unit>()
    private var cancelled = 0

    @Before fun setUp() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        terminal = TerminalView(activity, null).apply {
            setTerminalViewClient(makeViewClient {})
            setTextSize(20)
            setTypeface(Typeface.MONOSPACE)
        }
        session = TerminalSession(200, makeSessionClient({ terminal.onScreenUpdated() }, {}),
            object : TerminalSession.RemoteBridge {
                override fun onInput(data: ByteArray, offset: Int, count: Int) { sent.write(data, offset, count) }
                override fun onResize(columns: Int, rows: Int) {}
            })
        host = TerminalHistoryView(activity, terminal) { callback ->
            requests.add(callback)
            return@TerminalHistoryView { cancelled++ }
        }
        activity.setContentView(host)
        terminal.attachSession(session)
        layout()
        terminal.requestFocus()
        sent.reset()
    }

    private fun layout() {
        host.measure(View.MeasureSpec.makeMeasureSpec(600, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY))
        host.layout(0, 0, 600, 400)
    }
    private fun output(value: String) {
        val bytes = value.toByteArray()
        session.feedOutput(bytes, 0, bytes.size)
    }
    private fun deliver(index: Int, text: String) {
        requests[index](TerminalHistoryText(text, "conversation"))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        layout()
        shadowOf(android.os.Looper.getMainLooper()).idle()
    }
    private fun swipe() {
        for ((time, action, y) in listOf(Triple(1L, MotionEvent.ACTION_DOWN, 50f),
            Triple(40L, MotionEvent.ACTION_MOVE, 180f), Triple(80L, MotionEvent.ACTION_UP, 200f))) {
            val event = MotionEvent.obtain(1, time, action, 100f, y, 0)
            try { host.dispatchTouchEvent(event) } finally { event.recycle() }
        }
    }

    @Test fun fullScreenSwipeReadsHistoryWithoutEditingTheLiveDraft() {
        output("\u001b[?1049hFullscreen draft")
        val input = terminal.onCreateInputConnection(EditorInfo())
        input.setComposingText("1234", 1)
        sent.reset()
        swipe()
        assertTrue(host.isHistoryVisible)
        assertEquals(1, requests.size)
        assertEquals("", sent.toString("UTF-8"))
        deliver(0, (0..100).joinToString("\n") { "Output line $it" })
        assertTrue(host.historyScroll.scrollY > 0)
        val position = host.historyScroll.scrollY
        output("\u001b[Hlive redraw")
        assertEquals(position, host.historyScroll.scrollY)
        assertTrue(host.historyText.text.contains("Output line 0"))
        host.liveButton.performClick()
        assertFalse(host.isHistoryVisible)
        assertEquals("1234", input.getTextBeforeCursor(20, 0).toString())
        assertEquals("", sent.toString("UTF-8"))
        input.setComposingText("1235", 1)
        assertEquals("\u007f5", sent.toString("UTF-8"))
    }

    @Test fun mouseReportingAndNormalScrollbackDoNotOpenTheHistoryLayer() {
        repeat(80) { output("line $it\r\n") }
        swipe()
        assertFalse(host.isHistoryVisible)
        assertTrue(requests.isEmpty())
        assertEquals("", sent.toString("UTF-8"))
        output("\u001b[?1049h\u001b[?1003h\u001b[?1006h")
        swipe()
        assertFalse(host.isHistoryVisible)
        assertTrue(requests.isEmpty())
        assertTrue(sent.toString("UTF-8").contains("\u001b[<64;"))
    }

    @Test fun lateResponsesCannotResurrectClosedHistoryOrReplaceANewerDocument() {
        output("\u001b[?1049h")
        host.showHistory()
        host.returnToLive()
        assertEquals(1, cancelled)
        deliver(0, "stale first response")
        assertFalse(host.isHistoryVisible)
        host.showHistory()
        deliver(1, "current history")
        deliver(0, "stale again")
        assertEquals("current history", host.historyText.text.toString())
        host.dispose()
        deliver(1, "late after dispose")
        assertFalse(host.isHistoryVisible)
    }

    @Test fun typingReturnsToLiveAndPreservesTheSameInputConnection() {
        output("\u001b[?1049h")
        val input = terminal.onCreateInputConnection(EditorInfo())
        input.commitText("123", 1)
        host.showHistory()
        input.commitText("4", 1)
        assertFalse(host.isHistoryVisible)
        assertEquals("1234", sent.toString("UTF-8"))
        assertEquals("1234", input.getTextBeforeCursor(20, 0).toString())
    }
}
