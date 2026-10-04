package com.termux.view

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.termux.terminal.TerminalSession
import dev.universaltmux.android.MainActivity
import dev.universaltmux.android.Broker
import dev.universaltmux.android.Net
import dev.universaltmux.android.TerminalHistoryView
import dev.universaltmux.android.TerminalHistoryText
import dev.universaltmux.android.makeSessionClient
import dev.universaltmux.android.makeViewClient
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real production view on the phone, but with an isolated in-memory remote endpoint. */
@RunWith(AndroidJUnit4::class)
class TerminalDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private class Fixture(activity: Activity, historyHost: String? = null, historySession: String = "") {
        val view = TerminalView(activity, null)
        val label = TextView(activity)
        val input = StringBuilder()
        var cursor = 0
        val submitted = CountDownLatch(1)
        val laidOut = CountDownLatch(1)
        var submission = ""
        var writes = 0
        val historyLoaded = CountDownLatch(1)
        var loadedHistory: TerminalHistoryText? = null
        val history = TerminalHistoryView(activity, view) { result ->
            if (historyHost != null) {
                val call = Net.terminalHistory(Broker(historyHost, "http", "Test broker"), historySession) {
                    loadedHistory = it
                    result(it)
                    historyLoaded.countDown()
                }
                return@TerminalHistoryView { call.cancel() }
            }
            result(TerminalHistoryText((0..250).joinToString("\n\n") {
                "Output $it\nThe read-only history preserves previous output while the live application keeps working."
            }, "conversation"))
            return@TerminalHistoryView {}
        }
        val session: TerminalSession
        init {
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                if (view.mEmulator != null) laidOut.countDown()
            }
            label.setTextColor(Color.WHITE)
            label.setBackgroundColor(Color.DKGRAY)
            label.text = "Argus terminal verification\nIsolated test — no live agent input"
            label.textSize = 18f
            label.setPadding(20, 30, 20, 20)
            view.setTerminalViewClient(makeViewClient {
                (activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                    .showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
            })
            view.setTextSize(32)
            view.setTypeface(Typeface.MONOSPACE)
            view.isFocusableInTouchMode = true
            session = TerminalSession(2000, makeSessionClient({ view.onScreenUpdated() }, {}),
                object : TerminalSession.RemoteBridge {
                    override fun onResize(columns: Int, rows: Int) {}
                    override fun onInput(data: ByteArray, offset: Int, count: Int) {
                        writes++
                        val text = String(data, offset, count, Charsets.UTF_8)
                        when (text) {
                            "\u001b[D" -> cursor = (cursor - 1).coerceAtLeast(0)
                            "\u001b[C" -> cursor = (cursor + 1).coerceAtMost(input.length)
                            "\u001b[3~" -> if (cursor < input.length) input.deleteCharAt(cursor)
                            else -> text.forEach { c ->
                                when (c) {
                                    '\u007f', '\b' -> if (cursor > 0) input.deleteCharAt(--cursor)
                                    '\r', '\n' -> { submission = input.toString(); submitted.countDown() }
                                    else -> { input.insert(cursor, c); cursor++ }
                                }
                            }
                        }
                        label.text = "Argus terminal verification\nReceived exactly: $input"
                        output("\r\u001b[2KInput: $input")
                    }
                })
            val column = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(Color.BLACK)
                addView(label)
                addView(history, LinearLayout.LayoutParams(-1, 0, 1f))
            }
            activity.setContentView(column)
            view.attachSession(session)
            view.requestFocus()
        }
        fun output(text: String) {
            val bytes = text.toByteArray()
            session.feedOutput(bytes, 0, bytes.size)
        }
        fun topText() = view.mEmulator.screen.getSelectedText(0, view.mTopRow, 20, view.mTopRow)
    }

    /** Real HTTP loader + history UI, with no attach, resize, or input to the live session. */
    @Test fun brokerHistoryAndLiveReturn() {
        val args = InstrumentationRegistry.getArguments()
        val host = args.getString("historyHost")
        assumeTrue(host != null)
        val session = args.getString("historySession") ?: error("historySession required")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { fixture = Fixture(it, host, session) }
            assertTrue(fixture.laidOut.await(5, TimeUnit.SECONDS))
            scenario.onActivity {
                fixture.output("\u001b[?1049h\u001b[HIsolated terminal — real read-only broker history\r\nDraft: 1234")
                fixture.history.showHistory(-200f)
            }
            assertTrue("Broker must return history", fixture.historyLoaded.await(20, TimeUnit.SECONDS))
            assertEquals("conversation", fixture.loadedHistory?.origin)
            assertTrue("History must include earlier user turns", fixture.loadedHistory!!.text.contains("You\n"))
            instrumentation.waitForIdleSync()
            screenshot("terminal-broker-history.png")
            val live = UiDevice.getInstance(instrumentation).findObject(androidx.test.uiautomator.By.desc("Return to live terminal"))
            assertNotNull(live)
            live.click()
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertFalse(fixture.history.isHistoryVisible)
                assertEquals("Fetching and browsing real history must not send terminal input", 0, fixture.writes)
            }
            screenshot("terminal-broker-live-return.png")
        }
    }

    private fun screenshot(name: String) {
        instrumentation.waitForIdleSync()
        // Idle Java queues do not mean SurfaceFlinger has presented the changed
        // visibility/text yet. Wait for two display frames before inspecting it.
        val frames = CountDownLatch(1)
        instrumentation.runOnMainSync {
            android.view.Choreographer.getInstance().postFrameCallback {
                android.view.Choreographer.getInstance().postFrameCallback { frames.countDown() }
            }
        }
        assertTrue("A rendered frame must be presented", frames.await(3, TimeUnit.SECONDS))
        val file = File(instrumentation.targetContext.getExternalFilesDir(null), name)
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        println("TERMINAL_SCREENSHOT=${file.absolutePath}")
    }

    @Test fun editsAndScrollingOnDevice() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { fixture = Fixture(it) }
            assertTrue("Terminal must be laid out before receiving input", fixture.laidOut.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                val input = fixture.view.onCreateInputConnection(EditorInfo())
                input.setComposingText("1234", 1)
                input.finishComposingText()
                input.deleteSurroundingText(1, 0)
                input.setComposingRegion(0, 3)
                input.setComposingText("1235", 1)
                input.commitText("1235", 1)
                assertEquals("1235", fixture.input.toString())
            }
            screenshot("terminal-number-edit.png")
            val handler = Handler(Looper.getMainLooper())
            var sequence = 0
            val stream = object : Runnable {
                override fun run() {
                    fixture.output("stream ${sequence++}\r\n")
                    handler.postDelayed(this, 35)
                }
            }
            try {
                scenario.onActivity {
                    repeat(250) { fixture.output("history ${it.toString().padStart(4, '0')}\r\n") }
                    handler.post(stream)
                }
                val bounds = IntArray(4)
                scenario.onActivity {
                    fixture.view.getLocationOnScreen(bounds)
                    bounds[2] = fixture.view.width
                    bounds[3] = fixture.view.height
                }
                UiDevice.getInstance(instrumentation).swipe(
                    bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] / 4,
                    bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] * 3 / 4, 40)
                var anchor = ""
                scenario.onActivity {
                    fixture.view.mScroller.forceFinished(true)
                    assertTrue("Real swipe must move into history", fixture.view.mTopRow < 0)
                    anchor = fixture.topText()
                }
                Thread.sleep(300)
                scenario.onActivity { assertEquals("Live output must preserve the visible row", anchor, fixture.topText()) }
                screenshot("terminal-scroll-during-output.png")
            } finally { handler.removeCallbacks(stream) }
        }
    }

    @Test fun fullScreenHistoryAndLiveReturnOnDevice() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { fixture = Fixture(it) }
            assertTrue(fixture.laidOut.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            var writes = 0
            scenario.onActivity {
                fixture.output("\u001b[?1049h\u001b[HFull-screen application\r\nDraft remains untouched\r\n")
                fixture.view.onCreateInputConnection(EditorInfo()).commitText("1234", 1)
                writes = fixture.writes
            }
            val bounds = IntArray(4)
            scenario.onActivity {
                fixture.history.getLocationOnScreen(bounds)
                bounds[2] = fixture.history.width
                bounds[3] = fixture.history.height
            }
            val device = UiDevice.getInstance(instrumentation)
            device.swipe(bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] / 4,
                bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] * 3 / 4, 40)
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertTrue("Swipe must open read-only history", fixture.history.isHistoryVisible)
                assertEquals("Swiping must never emit terminal input", writes, fixture.writes)
                assertEquals("1234", fixture.input.toString())
                fixture.output("\u001b[HNew live output behind the history reader")
            }
            screenshot("terminal-fullscreen-history.png")
            // Exercise scrolling in both directions on the actual native ScrollView.
            device.swipe(bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] / 4,
                bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] * 3 / 4, 45)
            device.swipe(bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] * 3 / 4,
                bounds[0] + bounds[2] / 2, bounds[1] + bounds[3] / 4, 45)
            val live = device.findObject(androidx.test.uiautomator.By.desc("Return to live terminal"))
            assertNotNull("Live button is reachable", live)
            live.click()
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertFalse(fixture.history.isHistoryVisible)
                assertEquals(writes, fixture.writes)
                assertEquals("1234", fixture.input.toString())
            }
            screenshot("terminal-fullscreen-live-return.png")
        }
    }

    /** Optional automated keyboard probe: the driver taps the phone's real IME, not adb input text. */
    @Test fun realKeyboardNumberEdit() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("keyboardProbe") == "1")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var fixture: Fixture
            scenario.onActivity { fixture = Fixture(it) }
            assertTrue("Terminal must be laid out before receiving input", fixture.laidOut.await(5, TimeUnit.SECONDS))
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                fixture.view.post {
                    (it.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                        .showSoftInput(fixture.view, InputMethodManager.SHOW_IMPLICIT)
                }
            }
            println("TERMINAL_KEYBOARD_PROBE_READY")
            assertTrue("Keyboard driver must submit the isolated test line", fixture.submitted.await(90, TimeUnit.SECONDS))
            assertEquals("1235", fixture.submission)
            screenshot("terminal-real-keyboard-edit.png")
        }
    }
}
