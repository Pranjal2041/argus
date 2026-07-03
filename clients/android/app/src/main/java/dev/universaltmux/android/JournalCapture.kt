package dev.universaltmux.android

import android.content.Context
import android.os.Handler
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

// Phone-side activity journal capture: ONLY utterances (per the design — no
// dwell, no outcomes, no periodic monitoring; the phone journals only when the
// user speaks). Events queue in a SharedPreferences outbox and are flushed to
// the MAC broker's /journal/append inbox; the Mac app drains that into the
// canonical day files, deduping by event id.

// ---- utterance parser: 1:1 port of the Mac's JournalCore.UtteranceParser ----
// Printable bytes build `said` (backspace removes the last UTF-8 char, so the
// record is what was ultimately sent); semantic control keys land in `keys`
// (↑↓←→ ⏎ ⇥ ⎋ ^C…); terminal chatter that isn't the user speaking — SGR mouse
// reports, focus events, unknown CSI — is dropped. Bracketed paste is honored:
// Enter inside a paste is a newline, not an end.
class UtteranceParser {
    private val saidBytes = ArrayList<Byte>()
    var keys = ""; private set
    private var esc = false
    private var csiActive = false
    private var csi = ArrayList<Byte>()
    private var ss3 = false
    private var inPaste = false

    val said: String get() = String(saidBytes.toByteArray(), Charsets.UTF_8)
    val isEmpty: Boolean get() = saidBytes.isEmpty() && keys.isEmpty()

    /** Feed raw input bytes; true means "Enter pressed outside a paste" — finalize. */
    fun feed(bytes: ByteArray): Boolean {
        var finalize = false
        var i = 0
        while (i < bytes.size) {
            val b = bytes[i]; i++
            if (csiActive) {
                csi.add(b)
                val ub = b.toInt() and 0xff
                if (ub in 0x40..0x7e) endCSI()
                continue
            }
            if (ss3) { ss3 = false; continue }
            if (esc) {
                esc = false
                when (b) {
                    '['.code.toByte() -> { csiActive = true; csi = ArrayList(); continue }
                    'O'.code.toByte() -> { ss3 = true; continue }
                    else -> { keys += "⎋"; i-- ; continue }
                }
            }
            when (b.toInt() and 0xff) {
                0x1b -> esc = true
                0x0d, 0x0a -> if (inPaste) saidBytes.add(0x0a) else { keys += "⏎"; finalize = true }
                0x7f, 0x08 -> dropLastChar()
                0x09 -> keys += "⇥"
                0x03 -> keys += "^C"
                0x04 -> keys += "^D"
                0x1a -> keys += "^Z"
                in 0x00..0x1f -> { /* other control bytes: ignore */ }
                else -> saidBytes.add(b)
            }
        }
        return finalize
    }

    /** A dangling ESC at end-of-input (the user pressed the Esc key). */
    fun flushPending() {
        if (esc) { esc = false; keys += "⎋" }
    }

    private fun endCSI() {
        val bytes = csi.toByteArray()
        csiActive = false
        if (bytes.isEmpty()) return
        val final = bytes.last()
        val body = String(bytes, 0, bytes.size - 1, Charsets.UTF_8)
        if (final == '~'.code.toByte()) {
            if (body == "200") { inPaste = true; return }
            if (body == "201") { inPaste = false; return }
        }
        // Mouse reports and focus in/out are the terminal talking, not the user.
        if (body.startsWith("<") || final == 'M'.code.toByte()) return
        when (final) {
            'A'.code.toByte() -> keys += "↑"
            'B'.code.toByte() -> keys += "↓"
            'C'.code.toByte() -> keys += "→"
            'D'.code.toByte() -> keys += "←"
        }
    }

    private fun dropLastChar() {
        if (saidBytes.isEmpty()) return
        var n = saidBytes.size - 1
        while (n > 0 && (saidBytes[n].toInt() and 0xc0) == 0x80) n--
        while (saidBytes.size > n) saidBytes.removeAt(saidBytes.size - 1)
    }
}

/** Port of the Mac's echoConfirms: both sides reduced to alphanumerics so
 *  wrapping and input-box borders can't hide a genuine echo. */
fun echoConfirms(said: String, tail: String): Boolean {
    fun strip(s: String) = s.filter { it.isLetterOrDigit() }.lowercase()
    val needle = strip(said)
    if (needle.isEmpty()) return true
    return strip(tail).contains(needle.takeLast(12))
}

// ---- per-terminal capture session ------------------------------------------

/**
 * Owned by a RemoteTerminal. Coalesces input into utterances (Enter or 8s idle
 * ends one), captures the screen at typing-START, applies the patient secret
 * rule (looks at 1.5/4/8s; echo at any look keeps the text; silent-at-all
 * redacts), then hands the finished event to [JournalOutbox].
 */
class JournalUtterance(
    private val main: Handler,
    private val machineID: String,
    private val machineName: String,
    private val session: String,
    private val screenTail: (Int) -> List<String>,
) {
    private var parser = UtteranceParser()
    private var active = false
    private var id = ""
    private var saw: List<String> = emptyList()
    private var startedMs = 0L
    private val idle = Runnable { finalizeNow() }

    private val echoLooksMs = longArrayOf(1500, 4000, 8000)

    fun feed(bytes: ByteArray) {
        if (!active) {
            active = true
            id = UUID.randomUUID().toString().lowercase()
            saw = screenTail(60)   // BEFORE these keystrokes echo back
            startedMs = System.currentTimeMillis()
            parser = UtteranceParser()
        }
        val ended = parser.feed(bytes)
        main.removeCallbacks(idle)
        if (ended) finalizeNow() else main.postDelayed(idle, 8000)
    }

    fun finalizeNow() {
        if (!active) return
        active = false
        main.removeCallbacks(idle)
        parser.flushPending()
        if (parser.isEmpty) return
        val said = parser.said.take(4000)
        val keys = parser.keys
        // Zero-signal guard (parity with the Mac): stray whitespace, no keys.
        if (said.isBlank() && keys.isEmpty()) return
        val myID = id; val mySaw = saw; val t0 = startedMs

        if (said.isEmpty()) {
            emit(myID, mySaw, t0, null, keys, redacted = false)
            return
        }
        // Patient echo check: look at each deadline with a FRESH capture.
        fun look(i: Int) {
            val delay = echoLooksMs[i] - (if (i > 0) echoLooksMs[i - 1] else 0L)
            main.postDelayed({
                val tail = screenTail(60).joinToString("\n")
                when {
                    echoConfirms(said, tail) -> emit(myID, mySaw, t0, said, keys, redacted = false)
                    i + 1 < echoLooksMs.size -> look(i + 1)
                    // Silent at every look → genuinely hidden input (a password).
                    else -> emit(myID, mySaw, t0, said, keys, redacted = true)
                }
            }, delay)
        }
        look(0)
    }

    private fun emit(id: String, saw: List<String>, t0: Long,
                     said: String?, keys: String, redacted: Boolean) {
        val e = JSONObject()
        e.put("id", id)
        e.put("kind", "utterance")
        e.put("ts", isoMs(t0))
        e.put("v", 1)
        e.put("src", "phone")
        e.put("machineID", machineID)
        e.put("machine", machineName)
        e.put("session", session)
        if (keys.isNotEmpty()) e.put("keys", keys)
        val sawArr = JSONArray(); saw.forEach { sawArr.put(it.take(400)) }
        e.put("saw", sawArr)
        if (said != null) {
            if (redacted) { e.put("redacted", true); e.put("saidChars", said.length) }
            else e.put("said", said)
        }
        JournalOutbox.add(e)
    }

    companion object {
        private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
        fun isoMs(ms: Long): String = synchronized(iso) { iso.format(Date(ms)) }
    }
}

// ---- the outbox --------------------------------------------------------------

/** Resolved events wait here (SharedPreferences, survives process death) until
 *  the Mac broker is reachable; the Model's poll loop flushes them. */
object JournalOutbox {
    private const val KEY = "ut.journalOutbox.v1"
    private const val CAP = 200
    private var appCtx: Context? = null
    @Volatile var onAdded: (() -> Unit)? = null   // foreground fast-path flush

    fun init(ctx: Context) { appCtx = ctx.applicationContext }

    private fun prefs() = appCtx?.getSharedPreferences("ut", 0)

    @Synchronized
    fun add(e: JSONObject) {
        val p = prefs() ?: return
        val arr = JSONArray(p.getString(KEY, "[]") ?: "[]")
        arr.put(e)
        // Cap: drop oldest beyond CAP.
        val trimmed = if (arr.length() > CAP) {
            JSONArray().also { t -> for (i in arr.length() - CAP until arr.length()) t.put(arr.get(i)) }
        } else arr
        p.edit().putString(KEY, trimmed.toString()).apply()
        onAdded?.invoke()
    }

    /** All pending events as JSONL, or null if none. */
    @Synchronized
    fun pendingJSONL(): String? {
        val p = prefs() ?: return null
        val arr = JSONArray(p.getString(KEY, "[]") ?: "[]")
        if (arr.length() == 0) return null
        val sb = StringBuilder()
        for (i in 0 until arr.length()) sb.append(arr.getJSONObject(i).toString()).append('\n')
        return sb.toString()
    }

    /** Clear up to `count` oldest events (the ones just flushed). */
    @Synchronized
    fun clearFirst(count: Int) {
        val p = prefs() ?: return
        val arr = JSONArray(p.getString(KEY, "[]") ?: "[]")
        val rest = JSONArray()
        for (i in count until arr.length()) rest.put(arr.get(i))
        p.edit().putString(KEY, rest.toString()).apply()
    }

    @Synchronized
    fun pendingCount(): Int {
        val p = prefs() ?: return 0
        return JSONArray(p.getString(KEY, "[]") ?: "[]").length()
    }
}
