package dev.universaltmux.android

/** Binary wire protocol shared with the broker: [op u8][paneLen u8][pane][payload]. */
object Op {
    const val OUTPUT = 1        // server -> client: pane bytes
    const val INPUT = 2         // client -> server: keystrokes
    const val RESIZE = 3        // client -> server: payload = cols u16, rows u16 (big-endian) — an ASK
    const val REQ_SNAPSHOT = 4  // client -> server: send a fresh idempotent snapshot (clean repaint)
    const val PANE_SIZE = 5     // server -> client: the pane's AUTHORITATIVE cols×rows; output is
    // formatted for exactly this grid, so the emulator must pin to it or full-width lines shear
    const val SNAPSHOT_BEGIN = 6 // ordered repaint: preserve viewport, do not request another repaint
    const val SNAPSHOT_END = 7
}

/** A repaint contains its authoritative size; it must not trigger itself again. */
class TerminalRepaintPolicy {
    var inSnapshot = false
    private var columns = 0
    private var rows = 0

    fun onSize(columns: Int, rows: Int): Boolean {
        if (columns < 2 || rows < 2) return false
        val changed = columns != this.columns || rows != this.rows
        this.columns = columns
        this.rows = rows
        return changed && !inSnapshot
    }

    fun reset() { columns = 0; rows = 0; inSnapshot = false }
}

fun frame(op: Int, pane: String, payload: ByteArray): ByteArray {
    val p = pane.toByteArray(Charsets.UTF_8)
    val out = ByteArray(2 + p.size + payload.size)
    out[0] = op.toByte()
    out[1] = p.size.toByte()
    System.arraycopy(p, 0, out, 2, p.size)
    System.arraycopy(payload, 0, out, 2 + p.size, payload.size)
    return out
}

fun resizePayload(cols: Int, rows: Int): ByteArray = byteArrayOf(
    ((cols shr 8) and 0xff).toByte(), (cols and 0xff).toByte(),
    ((rows shr 8) and 0xff).toByte(), (rows and 0xff).toByte()
)

/** Returns (op, pane, payload) or null if malformed. */
fun decodeFrame(b: ByteArray): Triple<Int, String, ByteArray>? {
    if (b.size < 2) return null
    val op = b[0].toInt() and 0xff
    val paneLen = b[1].toInt() and 0xff
    if (b.size < 2 + paneLen) return null
    val pane = String(b, 2, paneLen, Charsets.UTF_8)
    val payload = b.copyOfRange(2 + paneLen, b.size)
    return Triple(op, pane, payload)
}
