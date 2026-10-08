package dev.universaltmux.android

import android.content.Context
import androidx.compose.runtime.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

object BrokerDocuments {
    fun url(broker: Broker, path: String, query: Map<String, String> = emptyMap()): String {
        val builder = (broker.httpBase + path).toHttpUrl().newBuilder()
        query.forEach { (key, value) -> builder.addQueryParameter(key, value) }
        return builder.build().toString()
    }
    fun read(broker: Broker, path: String, query: Map<String, String> = emptyMap(), timeoutSeconds: Long = 30): String =
        execute(Request.Builder().url(url(broker, path, query)).build(), timeoutSeconds)
    fun write(broker: Broker, path: String, query: Map<String, String>): String =
        execute(Request.Builder().url(url(broker, path, query)).post(ByteArray(0).toRequestBody()).build(), 60)
    private fun execute(request: Request, timeoutSeconds: Long): String = Net.client.newBuilder().readTimeout(timeoutSeconds, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
        val body = response.body?.string() ?: throw IOException("Empty broker response")
        val error = runCatching { JSONObject(body).optString("error").takeIf(String::isNotEmpty) }.getOrNull()
        if (!response.isSuccessful || error != null) throw IOException(error ?: "HTTP ${response.code}")
        body
    }
    fun digest(value: String): String = digest(value.toByteArray())
    fun digest(value: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(value).joinToString("") { "%02x".format(it) }
}

/** Durable, last-successful read models shared by screens, not their lifecycle. */
class BrokerDocumentCache(private val context: Context, private val scope: CoroutineScope) {
    private val documents = mutableStateMapOf<String, String>()
    val issues = mutableStateMapOf<String, String>()
    val loading = mutableStateListOf<String>()
    private fun key(broker: Broker, path: String, query: Map<String, String>) = BrokerDocuments.digest(
        (broker.brokerID.ifEmpty { broker.id }) + path + query.toSortedMap().toString())
    private fun file(key: String) = File(context.filesDir, "broker-documents/$key.txt")
    fun value(broker: Broker, path: String, query: Map<String, String> = emptyMap()): String? {
        val key = key(broker, path, query)
        if (key !in documents) runCatching { file(key).takeIf(File::isFile)?.readText() }.getOrNull()?.let { documents[key] = it }
        return documents[key]
    }
    fun issue(broker: Broker, path: String, query: Map<String, String> = emptyMap()) = issues[key(broker, path, query)]
    fun loading(broker: Broker, path: String, query: Map<String, String> = emptyMap()) = key(broker, path, query) in loading
    fun refresh(broker: Broker, path: String, query: Map<String, String> = emptyMap()) {
        val key = key(broker, path, query)
        if (key in loading) return
        loading.add(key)
        scope.launch {
            try {
                val data = withContext(Dispatchers.IO) {
                    val text = BrokerDocuments.read(broker, path, query)
                    val target = file(key); target.parentFile?.mkdirs()
                    val temp = File(target.path + ".tmp")
                    temp.outputStream().use { it.write(text.toByteArray()); it.fd.sync() }
                    check(temp.renameTo(target)) { "Could not retain this reading for offline use" }
                    text
                }
                documents[key] = data; issues.remove(key)
            } catch (error: Exception) { issues[key] = error.message ?: "Refresh failed; the cached reading is retained." }
            finally { loading.remove(key) }
        }
    }
}
