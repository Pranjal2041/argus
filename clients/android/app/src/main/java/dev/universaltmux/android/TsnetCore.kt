package dev.universaltmux.android

import android.content.Context
import android.os.Build
import android.util.Log
import dev.universaltmux.core.uttsnet.Engine
import dev.universaltmux.core.uttsnet.Uttsnet
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The embedded tsnet node (gomobile). The phone joins the tailnet as its OWN
 * device so it can enumerate peers and auto-discover brokers — no Tailscale app
 * or manual hostnames required. All engine calls BLOCK; run them off the main thread.
 */
object TsnetCore {
    @Volatile
    var engine: Engine? = null
        private set

    @Volatile
    var status: String = "off"

    val isUp get() = engine != null

    /** Join the tailnet using the shared auth key. Blocking. */
    fun start(ctx: Context, authKey: String): Boolean {
        if (engine != null) return true
        return try {
            status = "joining"
            val dir = File(ctx.filesDir, "tsnet").apply { mkdirs() }
            val model = (Build.MODEL ?: "android").lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')
            val host = "ut-phone-$model"
            val e = Uttsnet.new_(dir.absolutePath, host, authKey.trim(), Build.VERSION.SDK_INT.toLong())
            e.start() // blocks until the node has joined
            engine = e
            status = "up"
            Log.d("UTcore", "tsnet up as $host")
            true
        } catch (t: Throwable) {
            Log.e("UTcore", "tsnet start failed", t)
            status = "error: ${t.message ?: t.javaClass.simpleName}"
            false
        }
    }

    /** Enumerate online peers and return those running a broker. Blocking.
     * [BrokerDiscovery.authoritative] prevents a transient engine/status error
     * from being mistaken for an empty tailnet and pruning every saved node. */
    fun discover(): BrokerDiscovery {
        val e = engine ?: return BrokerDiscovery(emptyList(), false)
        return try {
            val json = e.discover()
            Log.d("UTcore", "discover -> $json")
            parseDiscovery(json)
        } catch (t: Throwable) {
            Log.e("UTcore", "discover failed", t)
            BrokerDiscovery(emptyList(), false)
        }
    }

    internal fun parseDiscovery(json: String): BrokerDiscovery {
        val trimmed = json.trim()
        val root = if (trimmed.startsWith("[")) null else JSONObject(trimmed)
        val arr = root?.optJSONArray("brokers") ?: JSONArray(trimmed)
        val brokers = (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            Broker(o.getString("host"), o.getString("scheme"),
                o.optString("name", o.getString("host")), o.optString("os", ""))
        }
        // Older locally-built cores returned a bare array and could not
        // distinguish an error from a real empty result. Merge non-empty
        // legacy answers, but only the new envelope is safe for empty prune.
        return BrokerDiscovery(brokers, root?.optBoolean("ok", false) ?: brokers.isNotEmpty())
    }
}
