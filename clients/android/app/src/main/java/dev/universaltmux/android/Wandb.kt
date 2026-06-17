package dev.universaltmux.android

import android.net.Uri

/** One detected Weights & Biases run advertised by a session's output. `discoveredAt`
 *  drives the 7-day expiry; it's excluded from equals/hashCode (it's a body property, not
 *  a data-class param) so re-detecting the same run with a fresh time isn't seen as a change. */
data class WandbRun(val url: String, val runId: String, val label: String) {
    var discoveredAt: Long = 0L
}

/** Kotlin port of the macOS `WandbDetector` (clients/macos/.../Wandb.swift). A battery of
 *  independent matchers run over ANSI-stripped text, deduped by run id, first-seen order. */
object WandbDetector {
    private val urlRe = Regex("""https?://[^\s"'<>)\]}]+""")

    // "View run <name> at: <url>", "Synced <name>: <url>", "Syncing run <name> to <url>",
    // "Run page / View project|sweep|run at: <url>" (group 1 = name, group 2 = url).
    private val namedMatchers = listOf(
        Regex("""(?i)(?:🚀\s*)?view run\s+(.+?)\s+at:?\s*(https?://[^\s"'<>)\]}]+)"""),
        Regex("""(?i)synced\s+(.+?):\s*(https?://[^\s"'<>)\]}]+)"""),
        Regex("""(?i)syncing run\s+(.+?)\s+to\s*(https?://[^\s"'<>)\]}]+)"""),
        Regex("""(?i)(?:run page|view project at|view sweep at|view run at)\s*:?\s*()(https?://[^\s"'<>)\]}]+)"""),
    )

    /** All runs found in `rawText`, first-seen order (so `.last()` is the latest). */
    fun runs(rawText: String): List<WandbRun> {
        val text = stripAnsi(rawText)
        val byId = LinkedHashMap<String, WandbRun>()   // insertion order = first-seen order

        fun consider(urlString: String, rawLabel: String?, trustContext: Boolean) {
            val cleaned = trimTrailing(urlString)
            val u = runCatching { Uri.parse(cleaned) }.getOrNull() ?: return
            val id = runId(u) ?: return
            if (!trustContext && !isWandbHost(u)) return
            val label = rawLabel?.trim(' ', '\t', '\'', '"', '“', '”', '·', '•', ':')
                ?.ifEmpty { null } ?: id
            val existing = byId[id]
            byId[id] = if (existing != null && existing.label != existing.runId && label == id)
                WandbRun(cleaned, id, existing.label)   // keep a real name once we have one
            else
                WandbRun(cleaned, id, label)
        }

        for (re in namedMatchers) for (m in re.findAll(text)) {          // (1) captioned, trusted
            consider(m.groupValues.getOrElse(2) { "" }, m.groupValues.getOrElse(1) { "" }.ifEmpty { null }, true)
        }
        for (line in text.split('\n')) {                                 // (2) wandb:/w&b lines, trusted
            val low = line.lowercase()
            if (low.contains("wandb:") || low.contains("w&b") || low.contains("weights & biases"))
                for (mu in urlRe.findAll(line)) consider(mu.value, null, true)
        }
        for (mu in urlRe.findAll(text)) consider(mu.value, null, false)   // (3) bare urls, host-gated

        return byId.values.toList()
    }

    private fun isWandbHost(u: Uri): Boolean {
        val host = (u.host ?: "").lowercase()
        if (host == "wandb.ai" || host.endsWith(".wandb.ai") || host.contains("wandb")) return true
        val segs = (u.path ?: "").split("/").filter { it.isNotEmpty() }   // self-hosted /<entity>/<project>/runs/<id>
        val ri = segs.indexOf("runs")
        return ri >= 2 && ri + 1 < segs.size
    }

    private fun runId(u: Uri): String? {
        val segs = (u.path ?: "").split("/").filter { it.isNotEmpty() }
        val ri = segs.indexOf("runs")
        return if (ri >= 0 && ri + 1 < segs.size) segs[ri + 1].ifEmpty { null } else null
    }

    private fun trimTrailing(s: String): String {
        var t = s
        while (t.isNotEmpty() && t.last() in ".,;:!?)]}'\"”’>") t = t.dropLast(1)
        return t
    }

    /** Strip ANSI/VT escapes by hand (CSI colors + OSC) so a run id printed in a different
     *  color rejoins its URL into one contiguous token. */
    private fun stripAnsi(s: String): String {
        val esc = '\u001B'; val bel = '\u0007'
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c != esc) { out.append(c); i++; continue }
            i++                                  // consume ESC
            if (i >= s.length) break
            val n = s[i]; i++
            if (n == '[') {                      // CSI: up to a final byte 0x40–0x7E
                while (i < s.length) { val p = s[i]; i++; if (p.code in 0x40..0x7E) break }
            } else if (n == ']') {               // OSC: up to BEL or ST (ESC \)
                while (i < s.length) { val p = s[i]; i++; if (p == bel) break; if (p == esc) { if (i < s.length) i++; break } }
            }                                    // else: 2-char ESC — n already consumed
        }
        return out.toString()
    }
}
