package dev.universaltmux.android

import android.content.Context
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

class WorkspaceBlobs(context: Context) {
    private val root = File(context.filesDir, "workspace-blobs")
    companion object { const val LIMIT = 128L * 1024 * 1024 }
    private fun valid(hash: String) = hash.matches(Regex("[0-9a-f]{64}"))
    private fun digest(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val size = input.read(buffer); if (size < 0) break; digest.update(buffer, 0, size) } }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    fun cached(hash: String): File? {
        require(valid(hash)) { "Invalid content hash" }
        return File(root, hash).takeIf { it.isFile && it.length() <= LIMIT && digest(it) == hash }
    }
    @Synchronized fun download(broker: Broker?, hash: String): File {
        cached(hash)?.let { return it }
        require(broker != null) { "Connect the workspace host to download this file" }
        root.mkdirs()
        val target = File(root, hash)
        val temporary = File.createTempFile("transfer-", ".tmp", root)
        try {
            val request = Request.Builder().url(broker.httpBase + "/workspace/blobs/$hash").build()
            Net.client.newBuilder().readTimeout(180, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw IOException("Download failed (HTTP ${response.code})")
                val body = response.body ?: throw IOException("Empty file response")
                if (body.contentLength() > LIMIT) throw IOException("Shared files are limited to 128 MiB")
                body.byteStream().use { input -> temporary.outputStream().use { out ->
                    val buffer = ByteArray(65536); var total = 0L
                    while (true) { val size = input.read(buffer); if (size < 0) break; total += size; if (total > LIMIT) throw IOException("File exceeds 128 MiB"); out.write(buffer, 0, size) }
                    out.fd.sync()
                } }
            }
            check(digest(temporary) == hash) { "The shared file did not match its content hash" }
            check(temporary.renameTo(target)) { "Could not retain the downloaded file" }
            return target
        } finally { temporary.delete() }
    }
    @Synchronized fun upload(broker: Broker, file: File): String {
        require(file.length() <= LIMIT) { "Shared files are limited to 128 MiB" }
        val hash = digest(file)
        val request = Request.Builder().url(broker.httpBase + "/workspace/blobs/$hash").put(file.asRequestBody()).build()
        Net.client.newBuilder().readTimeout(180, TimeUnit.SECONDS).writeTimeout(180, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Upload was not acknowledged (HTTP ${response.code})")
        }
        root.mkdirs()
        val target = File(root, hash)
        if (!target.isFile) file.copyTo(target)
        return hash
    }
}
