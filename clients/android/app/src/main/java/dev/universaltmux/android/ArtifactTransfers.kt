package dev.universaltmux.android

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.UUID

/** The local transfer journal bridges durable file staging and the durable
 * metadata outbox; a crash at either acknowledgment boundary is replay-safe. */
class ArtifactTransfers(private val context: Context, private val workspace: WorkspaceRepository, val blobs: WorkspaceBlobs) {
    private val root = File(context.filesDir, "artifact-transfers")
    var jobs by mutableStateOf<List<JSONObject>>(emptyList()); private set
    var issue by mutableStateOf<String?>(null); private set
    var uploading by mutableStateOf(false); private set
    private var nextAttempt = 0L
    init { reload() }
    private fun reload() {
        jobs = root.listFiles().orEmpty().filter { it.name.endsWith(".json") }.mapNotNull { file ->
            runCatching { JSONObject(file.readText()) }.getOrElse { issue = "A saved artifact transfer could not be read. Its files are retained."; null }
        }
    }
    fun activeJobs() = jobs.filter { it.optString("workspaceID") == workspace.workspaceID }
    suspend fun stage(input: InputStream, filename: String, contentType: String?, panel: JSONObject, brokerID: String? = null,
                      sourcePath: String? = null, kind: String = "file-snapshot", source: JSONObject? = null) {
        val owner = workspace.workspaceID
        if (owner.isEmpty()) { input.close(); error("Choose a workspace before saving an artifact") }
        withContext(Dispatchers.IO) {
            root.mkdirs()
            val id = UUID.randomUUID().toString()
            val file = File(root, "$id.blob")
            try {
                input.use { stream -> file.outputStream().use { output ->
                    var count = 0L; val buffer = ByteArray(65536)
                    while (true) { val size = stream.read(buffer); if (size < 0) break; count += size; require(count <= WorkspaceBlobs.LIMIT) { "Shared files are limited to 128 MiB" }; output.write(buffer, 0, size) }
                    output.fd.sync()
                } }
                val safeName = filename.substringAfterLast('/').substringAfterLast('\\').ifBlank { "artifact" }
                val ext = safeName.substringAfterLast('.', "").filter(Char::isLetterOrDigit).take(12)
                val record = JSONObject().put("schemaVersion", 1).put("id", id)
                    .put("filename", safeName).put("createdAt", Instant.now().truncatedTo(ChronoUnit.SECONDS).toString())
                    .put("kind", kind).put("panel", panel).put("presentation", "phone")
                    .put("relativePath", "files/$id${if (ext.isEmpty()) "" else ".$ext"}")
                    .put("byteCount", file.length()).put("contentType", contentType)
                    .put("sourcePath", sourcePath).put("titleSource", "source-filename")
                if (source != null) { File(root, "$id.source").outputStream().use { it.write(source.toString().toByteArray()); it.fd.sync() }; record.put("renderSourcePath", "sources/$id.json") }
                val job = JSONObject().put("workspaceID", owner).put("id", id).put("record", record).put("brokerID", brokerID)
                val temp = File(root, "$id.tmp")
                temp.outputStream().use { it.write(job.toString().toByteArray()); it.fd.sync() }
                check(temp.renameTo(File(root, "$id.json"))) { "Could not persist the artifact transfer" }
            } catch (error: Exception) { file.delete(); File(root, "$id.source").delete(); throw error }
        }
        reload()
    }
    suspend fun flush(host: Broker?, force: Boolean = false) {
        if (host == null || !workspace.loaded || uploading || (!force && System.currentTimeMillis() < nextAttempt)) return
        uploading = true
        try {
            val owner = workspace.workspaceID
            for (job in activeJobs()) {
                if (workspace.workspaceID != owner) break
                val id = job.getString("id")
                if (workspace.data("artifacts", id) == null && workspace.record("artifacts", id)?.deleted != true) {
                    val data = withContext(Dispatchers.IO) {
                        val value = JSONObject().put("record", job.getJSONObject("record"))
                            .put("hash", blobs.upload(host, File(root, "$id.blob")))
                        val source = File(root, "$id.source")
                        if (source.isFile) value.put("sourceHash", blobs.upload(host, source))
                        job.optString("brokerID").takeIf { it.isNotEmpty() }?.let { value.put("brokerID", it) }
                        value
                    }
                    if (workspace.workspaceID != owner) break
                    workspace.enqueue("artifacts", id, data)
                }
                withContext(Dispatchers.IO) {
                    // Removing the job first is safe because metadata is already
                    // in the atomic replica outbox and blobs are acknowledged.
                    check(File(root, "$id.json").delete()) { "Could not finalize artifact transfer" }
                    File(root, "$id.blob").delete(); File(root, "$id.source").delete()
                }
            }
            issue = null; nextAttempt = 0
        } catch (e: Exception) { issue = e.message; nextAttempt = System.currentTimeMillis() + 15000 }
        finally { uploading = false; reload() }
    }
}
