package dev.universaltmux.android

import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okio.BufferedSink
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/** Request body that reports byte-write progress (for the upload banner). */
private class ProgressBody(private val data: ByteArray, private val onProgress: (Long, Long) -> Unit) : RequestBody() {
    override fun contentType(): MediaType? = null
    override fun contentLength(): Long = data.size.toLong()
    override fun writeTo(sink: BufferedSink) {
        val total = data.size.toLong()
        var off = 0
        val chunk = 32 * 1024
        while (off < data.size) {
            val n = minOf(chunk, data.size - off)
            sink.write(data, off, n)
            off += n
            onProgress(off.toLong(), total)
        }
    }
}

/** A reachable broker. tsnet brokers serve real *.ts.net TLS (https/wss); a broker
 *  bound to a host's own tailnet IP (e.g. Windows via the Tailscale app) serves http/ws. */
data class Broker(val host: String, val scheme: String, val name: String) {
    val httpBase get() = "$scheme://$host:8722"
    val wsBase get() = (if (scheme == "https") "wss" else "ws") + "://$host:8722"
    val id get() = host
}

data class SessionInfo(
    val name: String,
    val attached: Boolean,
    val path: String,
    val state: String,
)

data class FileEntry(
    val name: String,
    val path: String,       // absolute, platform-native
    val isDir: Boolean,
    val size: Long,
    val mtime: Long,
    val mode: String,
)

data class FsHome(val home: String, val roots: List<String>, val sep: String)

data class PortInfo(val port: Int, val address: String, val process: String, val pid: Int)

/** HTTP + WebSocket to brokers. All traffic rides the encrypted tailnet. */
object Net {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(12, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    /** Probe a tailnet host:8722 for the broker handshake; returns the working scheme. */
    fun probe(host: String): Broker? {
        for (scheme in listOf("https", "http")) {
            try {
                val req = Request.Builder().url("$scheme://$host:8722/whoami").build()
                client.newCall(req).execute().use { r ->
                    val body = r.body?.string()
                    if (r.isSuccessful && body != null) {
                        val o = JSONObject(body)
                        if (o.optString("service") == "universal-tmux-broker") {
                            return Broker(host, scheme, o.optString("name", host))
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
        return null
    }

    fun sessions(b: Broker): List<SessionInfo>? = try {
        val req = Request.Builder().url("${b.httpBase}/sessions").build()
        client.newCall(req).execute().use { r ->
            val o = JSONObject(r.body!!.string())
            val arr = o.getJSONArray("sessions")
            (0 until arr.length()).map { i ->
                val s = arr.getJSONObject(i)
                SessionInfo(
                    s.getString("name"),
                    s.optBoolean("attached"),
                    s.optString("path", ""),
                    s.optString("state", ""),
                )
            }
        }
    } catch (_: Exception) {
        null
    }

    fun control(b: Broker, action: String, session: String, dir: String?) {
        try {
            val u = StringBuilder("${b.httpBase}/control?action=$action&session=${enc(session)}")
            if (dir != null) u.append("&dir=${enc(dir)}")
            val req = Request.Builder().url(u.toString())
                .post(RequestBody.create(null, ByteArray(0))).build()
            client.newCall(req).execute().close()
        } catch (_: Exception) {
        }
    }

    /** This host's listening TCP ports (for the port hub). */
    fun ports(b: Broker): List<PortInfo>? = try {
        val req = Request.Builder().url("${b.httpBase}/ports").build()
        client.newCall(req).execute().use { r ->
            val arr = JSONObject(r.body!!.string()).getJSONArray("ports")
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                PortInfo(o.getInt("port"), o.optString("address"), o.optString("process"), o.optInt("pid"))
            }.sortedBy { it.port }
        }
    } catch (_: Exception) { null }

    // --- file service (/fs) -------------------------------------------------

    fun fsHome(b: Broker): FsHome? = try {
        val req = Request.Builder().url("${b.httpBase}/fs/home").build()
        client.newCall(req).execute().use { r ->
            val o = JSONObject(r.body!!.string())
            val a = o.getJSONArray("roots")
            FsHome(o.getString("home"), (0 until a.length()).map { a.getString(it) }, o.optString("sep", "/"))
        }
    } catch (_: Exception) { null }

    fun fsList(b: Broker, path: String): List<FileEntry>? = try {
        val req = Request.Builder().url("${b.httpBase}/fs/list?path=${enc(path)}").build()
        client.newCall(req).execute().use { r ->
            val arr = JSONObject(r.body!!.string()).getJSONArray("entries")
            (0 until arr.length()).map { i ->
                val e = arr.getJSONObject(i)
                FileEntry(e.getString("name"), e.getString("path"), e.getBoolean("isDir"),
                    e.optLong("size"), e.optLong("mtime"), e.optString("mode"))
            }
        }
    } catch (_: Exception) { null }

    /** Raw file bytes (used for text + image previews). */
    fun fsReadBytes(b: Broker, path: String): ByteArray? = try {
        val req = Request.Builder().url("${b.httpBase}/fs/read?path=${enc(path)}").build()
        client.newCall(req).execute().use { r -> if (r.isSuccessful) r.body?.bytes() else null }
    } catch (_: Exception) { null }

    /** A streamable URL for the file (images/media in a viewer). */
    fun fsReadUrl(b: Broker, path: String) = "${b.httpBase}/fs/read?path=${enc(path)}"

    /** Stream a file into `sink`, reporting (bytesRead, total) progress. */
    fun fsDownloadTo(b: Broker, path: String, sink: java.io.OutputStream, onProgress: (Long, Long) -> Unit): Boolean = try {
        val req = Request.Builder().url("${b.httpBase}/fs/read?path=${enc(path)}").build()
        client.newCall(req).execute().use { r ->
            if (!r.isSuccessful) return false
            val body = r.body ?: return false
            val total = body.contentLength()
            body.byteStream().use { input ->
                val buf = ByteArray(32 * 1024); var read = 0L; var n: Int
                while (input.read(buf).also { n = it } >= 0) {
                    if (n > 0) { sink.write(buf, 0, n); read += n; onProgress(read, total) }
                }
            }
            true
        }
    } catch (_: Exception) { false }

    fun fsWrite(b: Broker, path: String, data: ByteArray, onProgress: ((Long, Long) -> Unit)? = null): Boolean = try {
        val body: RequestBody = if (onProgress != null) ProgressBody(data, onProgress) else RequestBody.create(null, data)
        val req = Request.Builder().url("${b.httpBase}/fs/write?path=${enc(path)}").post(body).build()
        client.newCall(req).execute().use { it.isSuccessful }
    } catch (_: Exception) { false }

    private fun fsOp(b: Broker, ep: String, params: List<Pair<String, String>>): Boolean = try {
        val u = StringBuilder("${b.httpBase}/fs/$ep?")
        params.forEachIndexed { i, (k, v) -> if (i > 0) u.append('&'); u.append("$k=${enc(v)}") }
        val req = Request.Builder().url(u.toString()).post(RequestBody.create(null, ByteArray(0))).build()
        client.newCall(req).execute().use { it.isSuccessful }
    } catch (_: Exception) { false }

    fun fsMkdir(b: Broker, path: String) = fsOp(b, "mkdir", listOf("path" to path))
    fun fsRename(b: Broker, from: String, to: String) = fsOp(b, "rename", listOf("path" to from, "to" to to))
    fun fsDelete(b: Broker, path: String) = fsOp(b, "delete", listOf("path" to path))

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")
}
