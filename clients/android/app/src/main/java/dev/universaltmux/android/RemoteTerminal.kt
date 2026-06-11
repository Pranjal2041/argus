package dev.universaltmux.android

import android.content.Context
import android.content.Context.INPUT_METHOD_SERVICE
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.inputmethod.InputMethodManager
import com.termux.terminal.TerminalSession
import com.termux.view.TerminalView
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString

private const val TAG = "UTerm"

/**
 * One live remote terminal: a Termux [TerminalView]+[TerminalSession] (in remote
 * mode) bridged to a broker over a binary WebSocket. Output frames feed the
 * emulator; the emulator's input/resize are sent back as protocol frames.
 */
class RemoteTerminal(
    private val context: Context,
    private val broker: Broker,
    private val sessionName: String,
) {
    private val main = Handler(Looper.getMainLooper())
    val view = TerminalView(context, null)

    private var ws: WebSocket? = null
    private var closed = false
    private var backoff = 500L

    /** Coalesced "repaint at the settled size" request after pane-size pins. */
    private val snapshotRequest = Runnable {
        ws?.send(frame(Op.REQ_SNAPSHOT, "", ByteArray(0)).toByteString())
    }

    private val bridge = object : TerminalSession.RemoteBridge {
        override fun onInput(data: ByteArray, offset: Int, count: Int) {
            ws?.send(frame(Op.INPUT, "", data.copyOfRange(offset, offset + count)).toByteString())
        }
        override fun onResize(columns: Int, rows: Int) {
            Log.d(TAG, "resize ${columns}x$rows (ws=${ws != null})")
            ws?.send(frame(Op.RESIZE, "", resizePayload(columns, rows)).toByteString())
        }
    }

    private val sessionClient = makeSessionClient(
        onChanged = { main.post { view.onScreenUpdated() } },
        onCopy = { },
    )
    val session = TerminalSession(10_000, sessionClient, bridge)

    init {
        view.setTerminalViewClient(makeViewClient(onTap = { showKeyboard() }))
        view.setTextSize(40)
        view.setTypeface(Typeface.MONOSPACE)
        view.attachSession(session)
        view.keepScreenOn = true
        connect()
    }

    private fun connect() {
        if (closed) return
        val url = "${broker.wsBase}/ws?session=${java.net.URLEncoder.encode(sessionName, "UTF-8")}"
        Log.d(TAG, "connecting $url")
        ws = Net.client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.d(TAG, "WS open ($url)")
                backoff = 500
                main.post { session.emulator?.let { bridge.onResize(it.mColumns, it.mRows) } }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val d = decodeFrame(bytes.toByteArray()) ?: return
                when (d.first) {
                    Op.OUTPUT -> {
                        val payload = d.third
                        main.post { session.feedOutput(payload, 0, payload.size) }
                    }
                    Op.PANE_SIZE -> {
                        // The pane's authoritative size (any tmux client may have set
                        // it): pin the emulator to exactly this grid, then ask for one
                        // clean repaint of the settled size (coalesced; the snapshot is
                        // idempotent server-side).
                        val p = d.third
                        if (p.size >= 4) {
                            val cols = ((p[0].toInt() and 0xff) shl 8) or (p[1].toInt() and 0xff)
                            val rows = ((p[2].toInt() and 0xff) shl 8) or (p[3].toInt() and 0xff)
                            Log.d(TAG, "paneSize ${cols}x$rows")
                            main.post {
                                session.setRemoteSize(cols, rows)
                                view.onScreenUpdated()
                                main.removeCallbacks(snapshotRequest)
                                main.postDelayed(snapshotRequest, 250)
                            }
                        }
                    }
                }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "WS fail: ${t.javaClass.simpleName}: ${t.message}", t)
                scheduleReconnect()
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WS closed $code $reason")
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        if (closed) return
        val delay = backoff
        backoff = (backoff * 2).coerceAtMost(10_000)
        main.postDelayed({ connect() }, delay)
    }

    /** Send raw bytes (accessory keys) straight to the session. */
    fun sendBytes(b: ByteArray) = session.write(b, 0, b.size)

    /** Text for the Renders screen: the whole transcript with soft-wrapped rows
     *  REJOINED (Termux's joinBackLines), tail-limited, agent gutters peeled —
     *  the same extraction contract as the Mac's renderableText(). */
    fun renderableText(maxLines: Int = 400): String {
        val screen = session.emulator?.screen ?: return ""
        val lines = screen.transcriptText.replace('\u0000', ' ').split("\n")
        return lines.takeLast(maxLines).joinToString("\n") { line ->
            val body = line.trimStart(' ')
            when {
                body.startsWith("⏺ ") || body.startsWith("⎿ ") -> body.substring(2)
                else -> line
            }
        }
    }

    /** Buffer rows (negative = scrollback) whose text contains `q` (case-insensitive). */
    fun findRows(q: String): List<Int> {
        val em = session.emulator ?: return emptyList()
        if (q.isBlank()) return emptyList()
        val screen = em.screen
        val out = ArrayList<Int>()
        for (r in -screen.activeTranscriptRows until em.mRows) {
            val text = screen.getSelectedText(0, r, em.mColumns, r, false)
            if (text.contains(q, ignoreCase = true)) out.add(r)
        }
        return out
    }

    fun scrollToBufferRow(row: Int) {
        view.scrollToBufferRow(row)
        view.onScreenUpdated()
    }

    fun showKeyboard() {
        view.isFocusableInTouchMode = true
        view.requestFocus()
        // Modern, reliable IME show; fall back to the legacy call.
        androidx.core.view.ViewCompat.getWindowInsetsController(view)
            ?.show(androidx.core.view.WindowInsetsCompat.Type.ime())
        (context.getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager)
            ?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
    }

    fun close() {
        closed = true
        ws?.cancel()
        ws = null
    }
}
