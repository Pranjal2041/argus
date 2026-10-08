package dev.universaltmux.android

import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.security.MessageDigest
import java.time.Instant
import kotlin.concurrent.thread

/** Separate .qa application, fixture-only HTTP server, and the production
 * screen components. No account, tailnet, credential, or live broker access. */
class ParityFixtureActivity : ComponentActivity() {
    private lateinit var vm: AppViewModel
    private lateinit var server: ParityFixtureServer
    private var screen by mutableStateOf(SCREEN_USAGE)
    fun showScreen(value: Int) { screen = value }
    fun configureStatusTest(stable: Boolean, reject: Boolean) {
        val broker = vm.brokers.first().copy(brokerID = if (stable) "fixture-broker" else "")
        vm.brokers[0] = broker
        server.rejectStatus = reject
        vm.ccStatus[broker.id + "/analysis"] = AgentCardStatus("analysis", "idle", "The comparison is ready for review.", null, 100.0)
        screen = 32
    }
    fun refreshStatusTest() { vm.refreshCC() }
    fun configurePartialStatusTest() {
        configureStatusTest(false, false)
        val broker = vm.brokers.first().copy(brokerID = "fixture-broker")
        vm.brokers[0] = broker
        vm.sessions[broker.id] = vm.sessions[broker.id]!!.map { it.copy(lineageID = "", tmuxId = "\$17") }
    }
    fun completeStatusTest() { server.statusApplied = true; vm.refreshCC() }
    fun currentStatusTest(): String = vm.ccFor(vm.brokers.first(), "analysis")?.label.orEmpty()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        check(packageName.endsWith(".qa"))
        getSharedPreferences("ut.files", 0).edit().clear().commit()
        val fixture = JSONObject(assets.open("replica-v1.json").bufferedReader().use { it.readText() })
        fixture.getJSONArray("records").objects().first { it.optString("id") == "wrapped" }.getJSONObject("data").getJSONObject("periods").getJSONObject("0").getJSONObject("totals").put("events", 320)
        server = ParityFixtureServer(fixture, JSONObject(assets.open("usage-connections-v1.json").bufferedReader().use { it.readText() }))
        val prefs = getSharedPreferences("ut", 0)
        prefs.edit().clear().putString("ut.workspace.id", "fixture-workspace")
            .putString("ut.replica.fixture-workspace", fixture.toString()).commit()
        vm = AppViewModel(application, startServices = false)
        val broker = Broker("127.0.0.1", "http", "Workspace host", "darwin", "fixture-broker", "fixture-workspace", true)
        vm.brokers.clear(); vm.brokers.add(broker)
        vm.sessions[broker.id] = listOf(SessionInfo("analysis", false, "/project", "waiting", lineageID = "lifetime-1", activityRevision = 12))
        vm.selected = broker to "analysis"
        vm.planner.add(PlannerCommitment(title = "Review the experiment comparison", project = "Training", deadline = Instant.now().plusSeconds(7200).toString()))
        vm.planner.add(PlannerCommitment(title = "Publish the reproducibility notes", project = "Training", deadline = Instant.now().minusSeconds(86400).toString()))
        setContent {
            CompositionLocalProvider(LocalTheme provides vm.theme) {
                MaterialTheme(colorScheme = darkColorScheme(primary = vm.theme.accent, background = vm.theme.bg, surface = vm.theme.panel)) {
                    Surface(Modifier.fillMaxSize()) {
                        Column {
                            Text("ARGUS  /  PARITY QA", modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.labelMedium)
                            Box(Modifier.weight(1f)) {
                                key(screen) { when (screen) {
                                    SCREEN_USAGE -> UsageScreen(vm)
                                    SCREEN_PLANNER -> PlannerScreen(vm)
                                    SCREEN_WORKSPACE -> WorkspaceScreen(vm)
                                    SCREEN_GIT -> GitScreen(vm)
                                    SCREEN_HISTORY -> HistoryScreen(vm) { _, _ -> }
                                    SCREEN_DASHBOARDS -> WorkspaceCatalogScreen(vm, notebooks = false)
                                    SCREEN_NOTEBOOKS -> WorkspaceCatalogScreen(vm, notebooks = true)
                                    SCREEN_ARTIFACTS -> ArtifactsScreen(vm)
                                    SCREEN_JOURNAL -> JournalScreen(vm, wrapped = false)
                                    SCREEN_WRAPPED -> JournalScreen(vm, wrapped = true)
                                    30 -> RenderOverlay(RenderContent(1, "# Experiment report\n\nA durable **PDF and authored source**.\n\n" + (1..45).joinToString("\n\n") { "## Result $it\nThe shared workspace preserves this result across devices." }, "fixture-transcript", panel = vm.artifactPanel(), brokerID = "fixture-broker"), {}, vm)
                                    31 -> FilesScreen(vm)
                                    32 -> CommandCenterScreen(vm) { _, _ -> }
                                    else -> App(vm)
                                } }
                            }
                        }
                    }
                }
            }
        }
    }
    override fun onDestroy() { server.close(); super.onDestroy() }
}

private class ParityFixtureServer(private val fixture: JSONObject, private val connections: JSONObject) : AutoCloseable {
    @Volatile var rejectStatus = false
    @Volatile var statusApplied = false
    private var statusQueued = false
    private val socket = ServerSocket(8722, 20, InetAddress.getByName("127.0.0.1"))
    private val blobs = mutableMapOf<String, ByteArray>()
    private var revision = fixture.getLong("cursor")
    private val receipts = mutableMapOf<String, JSONObject>()
    private var document = "# Analysis\n\nThe original file stays intact until a conditional save succeeds.\n"
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun record(collection: String, id: String, data: JSONObject) {
        fixture.getJSONArray("records").put(WorkspaceRecord(collection, id, ++revision, data).json()); fixture.put("cursor", revision)
    }
    init {
        val now = System.currentTimeMillis()
        val quota = JSONObject("""{"id":"quota-card","title":"Model quota","value":"74%","detail":"remaining this week","remaining":74,"sourceID":"quota","ordering":{"primary":"source:quota","members":[]}}""")
        val storage = JSONObject("""{"id":"storage-card","title":"Workspace storage","value":"1.2 TB","detail":"available · 48% free","remaining":48,"sourceID":"storage","ordering":{"primary":"source:storage","members":[]}}""")
        val warning = JSONObject("""{"id":"quota-warning","sourceID":"quota","title":"Model quota · research","detail":"8% short-window quota remaining","remaining":8,"critical":false,"cycle":"fixture"}""").put("resetsAt", now + 3600000)
        val accounts = JSONArray().put(JSONObject().put("id", "quota").put("title", "Model quota").put("account", "Research account").put("status", "Connected").put("observedAt", now).put("cards", JSONArray().put(quota)))
            .put(JSONObject().put("id", "storage").put("title", "Workspace storage").put("account", "Training data").put("status", "Connected").put("observedAt", now).put("cards", JSONArray().put(storage)))
        record("usage", "current", JSONObject().put("version", 1).put("lastRefresh", now).put("glances", JSONArray().put(quota).put(storage)).put("accounts", accounts)
            .put("warnings", JSONArray().put(warning)).put("failures", JSONArray()).put("sources", JSONArray().put(JSONObject("""{"id":"quota","account":"Research account","payload":{"quota":{"usedPercent":26,"remainingPercent":74}}}"""))))
        val day = java.time.LocalDate.now().toString()
        val journal = (JSONObject().put("id", "message-1").put("kind", "utterance").put("ts", Instant.now().toString()).put("machine", "Workspace host").put("session", "analysis").put("said", "Compare the two training runs and retain the full report.").put("saw", "Both runs finished. The evaluation table is ready.").put("src", "phone").toString() + "\n" +
            JSONObject().put("id", "status-1").put("kind", "status").put("ts", Instant.now().toString()).put("machine", "Workspace host").put("session", "analysis").put("to", "milestone").put("summary", "Evaluation report published.").toString() + "\n").toByteArray()
        val journalHash = hash(journal); blobs[journalHash] = journal
        record("journal", "fixture-broker/$day", JSONObject().put("kind", "day").put("day", day).put("hash", journalHash).put("count", 2))
        val output = ByteArrayOutputStream()
        val pdf = PdfDocument()
        try { repeat(2) { page ->
            val sheet = pdf.startPage(PdfDocument.PageInfo.Builder(595, 842, page + 1).create())
            sheet.canvas.drawText("Shared experiment report", 42f, 70f, Paint().apply { textSize = 25f })
            sheet.canvas.drawText("Page ${page + 1} of 2 · verified fixture", 42f, 110f, Paint().apply { textSize = 16f })
            pdf.finishPage(sheet)
        }; pdf.writeTo(output) } finally { pdf.close() }
        val bytes = output.toByteArray(); val pdfHash = hash(bytes); blobs[pdfHash] = bytes
        record("artifacts", "764e0a6e-f90f-41ab-9df0-e3a8a69b0da9", JSONObject().put("hash", pdfHash).put("record", JSONObject()
            .put("id", "764e0a6e-f90f-41ab-9df0-e3a8a69b0da9").put("filename", "Experiment report.pdf").put("createdAt", Instant.now().toString()).put("contentType", "application/pdf").put("byteCount", bytes.size)
            .put("panel", JSONObject().put("machineName", "Workspace host").put("sessionName", "analysis"))))
        thread(name = "parity-fixture-http", isDaemon = true) {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                thread(isDaemon = true) { client.use { connection ->
                    runCatching {
                        val input = connection.getInputStream().buffered()
                        fun line(): String { val out = StringBuilder(); while (true) { val b = input.read(); if (b < 0 || b == 10) return out.toString().trimEnd('\r'); out.append(b.toChar()) } }
                        val request = line().split(' '); val method = request[0]; val url = request[1]; var length = 0
                        while (true) { val header = line(); if (header.isEmpty()) break; if (header.startsWith("Content-Length:", true)) length = header.substringAfter(':').trim().toInt() }
                        val body = ByteArray(length); var offset = 0
                        while (offset < length) { val count = input.read(body, offset, length - offset); if (count < 0) break; offset += count }
                        val (status, result) = synchronized(this) { respond(method, url, body) }
                        val response = connection.getOutputStream()
                        response.write("HTTP/1.1 $status OK\r\nContent-Type: application/json\r\nContent-Length: ${result.size}\r\nConnection: close\r\n\r\n".toByteArray())
                        if (method != "HEAD") response.write(result)
                        response.flush()
                    }
                } }
            }
        }
    }
    @Synchronized private fun respond(method: String, url: String, bytes: ByteArray): Pair<Int, ByteArray> {
        val path = url.substringBefore('?')
        fun ok(value: Any) = 200 to value.toString().toByteArray()
        if (path.startsWith("/workspace/blobs/")) {
            val key = path.substringAfterLast('/')
            if (method == "PUT") { if (hash(bytes) != key) return 400 to ByteArray(0); blobs[key] = bytes; return ok(JSONObject().put("hash", key)) }
            return blobs[key]?.let { 200 to it } ?: (404 to ByteArray(0))
        }
        return when (path) {
            "/ccoverride" -> if (method == "POST") {
                if (rejectStatus) 503 to "{}".toByteArray() else { statusQueued = true; ok("{\"ok\":true}") }
            } else ok(JSONObject().put("overrides", JSONArray().also { if (statusQueued && !statusApplied) it.put(JSONObject().put("session", "analysis").put("label", "working").put("ts", 1234)) }))
            "/ccstatus" -> ok(JSONObject().put("items", JSONArray().put(JSONObject().put("session", "analysis").put("label", "idle")
                .put("summary", "The comparison is ready for review.").put("updatedAt", if (statusApplied) 102 else 101)
                .put("appliedOverrideTS", if (statusApplied) 1234 else 0))))
            "/workspace/service/usage" -> {
                val request = JSONObject(String(bytes))
                if (request.optString("action") == "save") {
                    val draft = request.getJSONObject("draft")
                    val id = draft.optString("sourceID", "fixture-new")
                    draft.put("id", id).put("sourceID", id).remove("credentials")
                    connections.put("connections", JSONArray(connections.getJSONArray("connections").objects().filterNot { it.optString("id") == id }).put(draft))
                }
                if (request.optString("action") == "remove") connections.put("connections", JSONArray(connections.getJSONArray("connections").objects().filterNot { it.optString("id") == request.optString("sourceID") }))
                ok(connections)
            }
            "/workspace/info", "/whoami" -> ok(JSONObject().put("protocol", 1).put("enabled", true).put("workspaceID", "fixture-workspace").put("brokerID", "fixture-broker").put("os", "darwin"))
            "/workspace/snapshot" -> ok(fixture)
            "/workspace/changes" -> ok(JSONObject().put("cursor", revision).put("records", fixture.getJSONArray("records")).put("more", false))
            "/workspace/mutate" -> {
                val body = JSONObject(String(bytes)); val id = body.getString("mutationID")
                receipts[id]?.let { return ok(it) }
                val current = fixture.getJSONArray("records").objects().firstOrNull { it.optString("collection") == body.optString("collection") && it.optString("id") == body.optString("id") }
                if ((current?.optLong("revision") ?: 0) != body.getLong("baseRevision")) return 409 to JSONObject().put("current", current ?: JSONObject().put("collection", body.getString("collection")).put("id", body.getString("id")).put("revision", 0)).toString().toByteArray()
                val record = WorkspaceRecord(body.getString("collection"), body.getString("id"), ++revision, body.optJSONObject("data"), body.optBoolean("delete")).json()
                fixture.put("records", JSONArray(fixture.getJSONArray("records").objects().filterNot { it === current }).put(record)); fixture.put("cursor", revision)
                val receipt = JSONObject().put("mutationID", id).put("record", record).put("cursor", revision); receipts[id] = receipt; ok(receipt)
            }
            "/git/summary" -> ok("""{"branch":"feature/shared-workspace","upstream":"origin/main","ahead":2,"behind":0,"stashes":0,"root":"/project","files":[{"path":"analysis.md","staged":"M","unstaged":".","untracked":false},{"path":"src/workspace.kt","staged":"M","unstaged":".","untracked":false},{"path":"tests/sync_test.kt","staged":".","unstaged":"M","untracked":false}]}""")
            "/git/diff", "/git/pr/diff" -> ok("diff --git a/src/workspace.kt b/src/workspace.kt\n--- a/src/workspace.kt\n+++ b/src/workspace.kt\n@@ -1 +1 @@\n-old()\n+shared()\n")
            "/git/log" -> ok("""[{"hash":"abc123","short":"abc123","subject":"Preserve pending writes across restart","author":"Developer","date":"2026-10-04"}]""")
            "/git/prs" -> ok("""[{"number":42,"title":"Shared workspace parity","state":"OPEN","headRefName":"feature/shared-workspace","author":{"login":"developer"}}]""")
            "/git/pr" -> ok("""{"number":42,"title":"Shared workspace parity","body":"Review the durable replica and client readers.","state":"OPEN","files":[{"path":"src/workspace.kt","additions":24,"deletions":2}],"comments":[],"reviews":[],"statusCheckRollup":[{"name":"tests","conclusion":"SUCCESS"}]}""")
            "/history" -> ok("""{"sessions":[{"name":"analysis","node":"Workspace host","agent":false,"alive":true,"first":1791150000,"last":1791158400,"folders":[{"path":"/project","first":1791150000,"last":1791158400}]}]}""")
            "/fs/home" -> ok("""{"home":"/project","sep":"/","roots":["/"]}""")
            "/fs/list" -> ok("""{"entries":[{"name":"analysis.md","path":"/project/analysis.md","isDir":false,"size":120},{"name":"results.txt","path":"/project/results.txt","isDir":false,"size":60}]}""")
            "/fs/grep" -> ok("""{"root":"/project","matches":[{"path":"/project/analysis.md","line":3,"text":"The original file stays intact until a conditional save succeeds."}],"truncated":false}""")
            "/fs/document" -> {
                if (method == "POST") document = JSONObject(String(bytes)).getString("text")
                ok(JSONObject().put("path", "/project/analysis.md").put("text", document).put("revision", hash(document.toByteArray())))
            }
            "/sessions" -> ok("[]")
            else -> ok("{}")
        }
    }
    override fun close() { socket.close() }
}
