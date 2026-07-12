package dev.universaltmux.android

import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URLEncoder

/** Synchronous Lab HTTP client. AppViewModel calls it only from Dispatchers.IO. */
object LabNet {
    fun snapshot(broker: Broker): LabBrokerSnapshot {
        val notesResponse = getObject("${broker.httpBase}/lab/notes")
        val notes = notesResponse?.optJSONArray("notes")?.objects()?.map(::parseHubNote)
        val store = notesResponse?.stringOrNull("store")

        val metas = getObject("${broker.httpBase}/lab/sets")?.optJSONArray("sets")
            ?.objects()?.map(::parseSetMeta).orEmpty()
        val briefs = metas.mapNotNull { meta ->
            getObject("${broker.httpBase}/lab/brief?set=${enc(meta.id)}")?.let(::parseBrief)
        }
        val keys = getObject("${broker.httpBase}/lab/keys")?.optJSONArray("keys")
            ?.objects()?.map(::parseKey).orEmpty()
        val proposals = getObject("${broker.httpBase}/lab/proposals")?.optJSONArray("proposals")
            ?.objects()?.map(::parseProposal).orEmpty()
        return LabBrokerSnapshot(broker, store, briefs, keys, proposals, notes)
    }

    fun mirror(broker: Broker): List<LabMirrored> =
        getObject("${broker.httpBase}/lab/mirror")?.optJSONArray("mirror")?.objects()?.mapNotNull { item ->
            val brief = item.optJSONObject("brief") ?: return@mapNotNull null
            LabMirrored(
                item.optString("machine"), item.optString("set"), item.optString("updated"), parseBrief(brief),
            )
        }.orEmpty()

    fun decideKey(item: LabPendingKey, approve: Boolean, project: String, note: String = ""): Boolean = post(
        item.broker, "/lab/decide",
        listOf(
            "key" to item.key.key.take(8), "approve" to if (approve) "1" else "0",
            "project" to project.trim(), "note" to note.trim(),
        ),
    )

    fun decideRun(card: LabSetCard, run: String, approve: Boolean, note: String): Boolean = post(
        card.broker, "/lab/decide-run",
        listOf("set" to card.brief.set.id, "run" to run, "approve" to if (approve) "1" else "0", "note" to note.trim()),
    )

    fun postNote(
        broker: Broker,
        scope: String,
        text: String,
        project: String = "",
        set: String = "",
        run: String = "",
    ): Boolean = post(
        broker, "/lab/note",
        listOf("scope" to scope, "text" to text.trim(), "project" to project, "set" to set, "run" to run),
    )

    fun hide(
        broker: Broker,
        target: String,
        set: String = "",
        scope: String = "",
        project: String = "",
    ): Boolean = post(
        broker, "/lab/hide",
        listOf("target" to target, "set" to set, "scope" to scope, "project" to project),
    )

    fun archive(card: LabSetCard, run: String = "", on: Boolean): Boolean = post(
        card.broker, "/lab/archive",
        listOf("set" to card.brief.set.id, "run" to run, "on" to if (on) "1" else "0"),
    )

    fun policy(card: LabSetCard, policy: String): Boolean = post(
        card.broker, "/lab/policy", listOf("set" to card.brief.set.id, "policy" to policy),
    )

    fun revoke(card: LabSetCard, key: String): Boolean = post(
        card.broker, "/lab/revoke", listOf("key" to key.take(8)),
    )

    fun runDetail(card: LabSetCard, run: String): LabRunDetail {
        val events = events(card, run)
        if (card.offline) return LabRunDetail(events = events)
        val files = getObject(
            "${card.broker.httpBase}/lab/files?set=${enc(card.brief.set.id)}&run=${enc(run)}",
        )?.optJSONArray("files")?.objects()?.map {
            LabRunFileInfo(it.optString("name"), it.optLong("size"))
        }.orEmpty()
        val names = files.mapTo(hashSetOf()) { it.name }
        val text = linkedMapOf<String, String>()
        listOf("snapshot/diff.patch", "files/env.txt").forEach { name ->
            if (name in names) fileText(card, run, name)?.let { text[name] = it }
        }
        if ("log.txt" in names) fileText(card, run, "log.txt", tail = 16_000)?.let { text["log.txt"] = it }
        val envelope = events.firstOrNull { it.kind == "run-start" }?.data
            ?: events.firstOrNull { it.kind == "proposal" }?.data
        envelope?.params.orEmpty().forEach { ref ->
            val name = "files/" + ref.path.replace('\\', '/').substringAfterLast('/')
            if (name in names) fileText(card, run, name)?.let { text[name] = it }
        }
        return LabRunDetail(events, files, text)
    }

    fun artifact(card: LabSetCard, run: String, name: String): String? = fileText(card, run, name)

    private fun events(card: LabSetCard, run: String): List<LabEvent> {
        val url = buildString {
            append("${card.broker.httpBase}/lab/events?set=${enc(card.brief.set.id)}&run=${enc(run)}")
            if (card.offline) append("&machine=${enc(card.machineName)}")
        }
        return getObject(url)?.optJSONArray("events")?.objects()?.map(::parseEvent).orEmpty()
    }

    private fun fileText(card: LabSetCard, run: String, name: String, tail: Int? = null): String? {
        if (card.offline) return null
        val url = buildString {
            append("${card.broker.httpBase}/lab/file?set=${enc(card.brief.set.id)}&run=${enc(run)}&name=${enc(name)}")
            if (tail != null) append("&tail=$tail")
        }
        return try {
            Net.client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                if (!response.isSuccessful) return null
                val input = response.body?.byteStream() ?: return null
                input.use { String(readCapped(it, 2_000_000), Charsets.UTF_8) }
            }
        } catch (_: Exception) { null }
    }

    private fun readCapped(input: InputStream, limit: Int): ByteArray {
        val output = ByteArrayOutputStream(minOf(limit, 64 * 1024))
        val buffer = ByteArray(16 * 1024)
        var remaining = limit
        while (remaining > 0) {
            val count = input.read(buffer, 0, minOf(buffer.size, remaining))
            if (count < 0) break
            output.write(buffer, 0, count)
            remaining -= count
        }
        return output.toByteArray()
    }

    private fun post(broker: Broker, path: String, query: List<Pair<String, String>>): Boolean = try {
        val suffix = query.filter { it.second.isNotEmpty() }.joinToString("&") { "${it.first}=${enc(it.second)}" }
        val request = Request.Builder().url("${broker.httpBase}$path?$suffix")
            .post(ByteArray(0).toRequestBody(null)).build()
        Net.client.newCall(request).execute().use { it.isSuccessful }
    } catch (_: Exception) { false }

    private fun getObject(url: String): JSONObject? = try {
        Net.client.newCall(Request.Builder().url(url).build()).execute().use { response ->
            if (!response.isSuccessful) null else response.body?.string()?.let(::JSONObject)
        }
    } catch (_: Exception) { null }

    private fun parseSetMeta(o: JSONObject) = LabSetMeta(
        o.optString("id"), o.optString("project"), o.optString("machine"),
        o.optString("cwd"), o.optString("created"),
    )

    private fun parseKey(o: JSONObject) = LabKeyInfo(
        key = o.optString("key"), set = o.stringOrNull("set"), project = o.optString("project"),
        machine = o.optString("machine"), cwd = o.optString("cwd"), session = o.stringOrNull("session"),
        status = o.optString("status"), created = o.optString("created"),
    )

    private fun parseProposal(o: JSONObject) = LabProposal(
        set = o.optString("set"), run = o.optString("run"), project = o.optString("project"),
        machine = o.optString("machine"), intent = o.optString("intent"), tier = o.stringOrNull("tier"),
        group = o.stringOrNull("group"), argv = o.optJSONArray("argv").strings(),
        cwd = o.stringOrNull("cwd"), created = o.optString("created"),
    )

    private fun parseBrief(o: JSONObject): LabBrief {
        val set = parseSetMeta(o.optJSONObject("set") ?: JSONObject())
        return LabBrief(
            set = set,
            policy = o.optString("policy", "full-only"),
            notes = o.optJSONArray("notes")?.objects()?.map(::parseEvent).orEmpty(),
            setEvents = o.optJSONArray("setEvents")?.objects()?.map(::parseEvent).orEmpty(),
            runs = o.optJSONArray("runs")?.objects()?.map { run ->
                LabRunSummary(
                    id = run.optString("id"), group = run.stringOrNull("group"), tier = run.stringOrNull("tier"),
                    status = run.optString("status"), started = run.stringOrNull("started"),
                    latest = run.stringOrNull("latest"), exitCode = run.optInt("exitCode", -1),
                    archived = run.optBoolean("archived", false),
                )
            }.orEmpty(),
            archived = o.optBoolean("archived", false),
        )
    }

    private fun parseHubNote(o: JSONObject) = LabHubNote(
        scope = o.optString("scope"), project = o.stringOrNull("project"), id = o.optString("id"),
        time = o.optString("time"), author = o.optString("author"), text = o.optString("text"),
        hidden = o.optBoolean("hidden", false),
    )

    private fun parseEvent(o: JSONObject): LabEvent {
        val data = o.optJSONObject("data")?.let(::parseEventData)
        return LabEvent(
            o.optString("id"), o.optString("time"), o.optString("author"), o.optString("kind"),
            o.stringOrNull("text"), data,
        )
    }

    private fun parseEventData(o: JSONObject): LabEventData {
        val snapshot = o.optJSONObject("snapshot")?.let {
            LabSnapshotInfo(
                it.stringOrNull("baseSha"), it.optBoolean("noGit", false),
                it.optLong("patchBytes", 0), it.optInt("archived", 0),
            )
        }
        val env = o.optJSONObject("env")?.let {
            LabEnvFacts(it.stringOrNull("os"), it.stringOrNull("arch"), it.stringOrNull("python"), it.stringOrNull("gpus"))
        }
        return LabEventData(
            target = o.stringOrNull("target"), argv = o.optJSONArray("argv").strings(), cwd = o.stringOrNull("cwd"),
            tier = o.stringOrNull("tier"), group = o.stringOrNull("group"),
            tmuxSession = o.stringOrNull("tmuxSession"), bind = o.stringOrNull("bind"), snapshot = snapshot,
            params = o.optJSONArray("params")?.objects()?.map(::parseFileRef).orEmpty(),
            dataFiles = o.optJSONArray("dataFiles")?.objects()?.map(::parseFileRef).orEmpty(), env = env,
            exitCode = if (o.has("exit") && !o.isNull("exit")) o.optInt("exit") else null,
            durationSec = if (o.has("durationSec") && !o.isNull("durationSec")) o.optInt("durationSec") else null,
            wandb = o.optJSONArray("wandb").strings(), drift = o.optJSONArray("drift").strings(),
        )
    }

    private fun parseFileRef(o: JSONObject) = LabFileRef(o.optString("path"), o.stringOrNull("sha256"))

    private fun JSONObject.stringOrNull(key: String): String? =
        if (!has(key) || isNull(key)) null else optString(key).takeIf { it.isNotEmpty() && it != "null" }

    private fun JSONArray?.objects(): List<JSONObject> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }

    private fun JSONArray?.strings(): List<String> =
        if (this == null) emptyList() else (0 until length()).mapNotNull { optString(it).takeIf(String::isNotEmpty) }

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}
