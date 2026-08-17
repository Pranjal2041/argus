package dev.universaltmux.android

import android.content.Context
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.OutputStream

data class WeeklyProgressReply(
    val successful: Boolean,
    val status: Int,
    val body: String,
    val error: String?,
)

object WeeklyProgressNet {
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    @Volatile private var lastCatalogSaveAt = 0L
    @Volatile private var lastCachePruneAt = 0L

    fun catalog(broker: Broker): Pair<WeeklyProgressCatalog, String>? = try {
        val request = Request.Builder().url("${broker.httpBase}/weekly-progress/catalog").build()
        Net.client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val raw = response.body?.string() ?: return null
            WeeklyProgressCatalog.parse(raw) to raw
        }
    } catch (_: Exception) { null }

    fun generate(broker: Broker, projectId: String, weekStart: String, requestId: String): WeeklyProgressReply =
        command(
            broker,
            "generate",
            JSONObject()
                .put("project_id", projectId)
                .put("week_start", weekStart)
                .put("request_id", requestId),
        )

    fun resume(broker: Broker, generationId: String, requestId: String): WeeklyProgressReply =
        command(
            broker,
            "resume",
            JSONObject()
                .put("generation_id", generationId)
                .put("request_id", requestId),
        )

    private fun command(broker: Broker, endpoint: String, payload: JSONObject): WeeklyProgressReply = try {
        val request = Request.Builder()
            .url("${broker.httpBase}/weekly-progress/$endpoint")
            .post(payload.toString().toRequestBody(jsonType))
            .build()
        Net.client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            val error = runCatching { JSONObject(body).optString("error").ifBlank { null } }.getOrNull()
            WeeklyProgressReply(response.isSuccessful, response.code, body, error)
        }
    } catch (error: Exception) {
        WeeklyProgressReply(false, 0, "", error.localizedMessage ?: "The Mac could not be reached.")
    }

    fun slideBytes(context: Context, broker: Broker?, generationId: String, slide: Int): ByteArray? {
        val file = slideCacheFile(context, generationId, slide)
        if (file.isFile && file.length() > 0) return runCatching { file.readBytes() }.getOrNull()
        if (broker == null) return null
        return try {
            val request = Request.Builder()
                .url("${broker.httpBase}/weekly-progress/asset/$generationId/slide/$slide")
                .build()
            Net.client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return null
                val bytes = response.body?.bytes() ?: return null
                file.parentFile?.mkdirs()
                val temporary = File(file.parentFile, file.name + ".tmp")
                temporary.writeBytes(bytes)
                if (!temporary.renameTo(file)) {
                    file.writeBytes(bytes)
                    temporary.delete()
                }
                bytes
            }
        } catch (_: Exception) { null }
    }

    fun report(context: Context, broker: Broker?, generationId: String): String? {
        val file = File(context.cacheDir, "weekly-progress/$generationId/research-report.md")
        val remote = if (broker == null) null else try {
            val request = Request.Builder()
                .url("${broker.httpBase}/weekly-progress/asset/$generationId/report")
                .build()
            Net.client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) null else response.body?.string()
            }
        } catch (_: Exception) { null }
        if (remote != null) {
            runCatching { file.parentFile?.mkdirs(); file.writeText(remote) }
            return remote
        }
        return runCatching { file.takeIf { it.isFile }?.readText() }.getOrNull()
    }

    fun downloadDeck(
        broker: Broker,
        generationId: String,
        sink: OutputStream,
        onProgress: (Long, Long) -> Unit,
    ): Boolean = try {
        val request = Request.Builder()
            .url("${broker.httpBase}/weekly-progress/asset/$generationId/deck")
            .build()
        Net.client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return false
            val body = response.body ?: return false
            val total = body.contentLength()
            body.byteStream().use { input ->
                val buffer = ByteArray(32 * 1024)
                var written = 0L
                var lastReported = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    sink.write(buffer, 0, count)
                    written += count
                    if (written - lastReported >= 512 * 1024 || written == total) {
                        lastReported = written
                        onProgress(written, total)
                    }
                }
                if (written != lastReported) onProgress(written, total)
            }
            true
        }
    } catch (_: Exception) { false }

    fun loadCachedCatalog(context: Context): WeeklyProgressCatalog? = runCatching {
        val file = catalogFile(context)
        file.takeIf { it.isFile }?.readText()?.let(WeeklyProgressCatalog::parse)
    }.getOrNull()

    fun saveCatalog(context: Context, raw: String) {
        val now = System.currentTimeMillis()
        if (now - lastCatalogSaveAt < 30_000L) return
        lastCatalogSaveAt = now
        runCatching {
            val file = catalogFile(context)
            file.parentFile?.mkdirs()
            file.writeText(raw)
        }
        pruneCacheIfNeeded(context, now)
    }

    private fun catalogFile(context: Context) =
        File(context.filesDir, "weekly-progress/catalog-v1.json")

    private fun slideCacheFile(context: Context, generationId: String, slide: Int) =
        File(context.cacheDir, "weekly-progress/$generationId/slide-$slide.png")

    private fun pruneCacheIfNeeded(context: Context, now: Long) {
        if (now - lastCachePruneAt < 12L * 60 * 60 * 1000) return
        lastCachePruneAt = now
        runCatching {
            val root = File(context.cacheDir, "weekly-progress")
            if (!root.isDirectory) return@runCatching
            val maxAge = 30L * 24 * 60 * 60 * 1000
            root.walkBottomUp().filter { it.isFile && now - it.lastModified() > maxAge }.forEach(File::delete)
            val files = root.walkTopDown().filter(File::isFile).sortedBy(File::lastModified).toList()
            var total = files.sumOf(File::length)
            val limit = 250L * 1024 * 1024
            for (file in files) {
                if (total <= limit) break
                val size = file.length()
                if (file.delete()) total -= size
            }
            root.walkBottomUp().filter { it.isDirectory && it.list()?.isEmpty() == true }.forEach(File::delete)
        }
    }
}
