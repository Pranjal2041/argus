package dev.universaltmux.android

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.universaltmux.core.uttsnet.Forward as CoreForward
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val pInk = Color(0xFF0D0E12)
private val pPanel = Color(0xFF16161E)
private val pAccent = Color(0xFF7AA2F7)
private val pLive = Color(0xFF61D6AA)
private val pDim = Color(0xFF9AA5CE)
private val pFaint = Color(0xFF565F89)

/** One active local-port -> remote-broker tunnel running on the phone. */
class ActiveForward(
    val brokerHost: String, val brokerName: String, val scheme: String,
    val remotePort: Int, val localPort: Int, val label: String,
    val handle: CoreForward,
) {
    val id = "$brokerHost#$remotePort#$localPort"
    /** "connecting" | "live" | "broken" — driven by the service's health poller. */
    var health by androidx.compose.runtime.mutableStateOf("connecting")
}

/**
 * App-wide registry of active forwards (persists across screen switches). Each
 * start/stop reconciles [ForwardService] so the process stays alive (foreground
 * notification) exactly while ≥1 forward is running — the fix for forwards dying
 * the moment you leave Argus for the browser.
 */
object Forwards {
    val active = androidx.compose.runtime.mutableStateListOf<ActiveForward>()

    /** Application context, set once at startup so start/stop can drive the service. */
    @Volatile var appCtx: android.content.Context? = null

    /** Starts a forward; returns null on success or an error string. */
    fun start(b: Broker, remotePort: Int, label: String): String? {
        val e = TsnetCore.engine ?: return "tailnet not connected"
        if (active.any { it.brokerHost == b.host && it.remotePort == remotePort }) return null // already forwarding
        return try {
            val f = e.startForward(b.host, b.scheme, remotePort.toLong(), remotePort.toLong())
            active.add(ActiveForward(b.host, b.name, b.scheme, remotePort, f.localPort().toInt(), label, f))
            appCtx?.let { ForwardService.sync(it) }
            null
        } catch (t: Throwable) {
            t.message ?: "forward failed"
        }
    }

    fun stop(af: ActiveForward) {
        try { af.handle.stop() } catch (_: Throwable) {}
        active.remove(af)
        appCtx?.let { ForwardService.sync(it) }
    }

    /** Stop every forward (used by the notification's "Stop all"); no service sync —
     *  the service stops itself right after calling this. */
    fun clearAll() {
        active.toList().forEach { try { it.handle.stop() } catch (_: Throwable) {} }
        active.clear()
    }
}

@Composable
fun PortsScreen(vm: AppViewModel) {
    val brokers = vm.brokers
    if (brokers.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No hosts yet — add a broker first.", color = pDim) }
        return
    }
    var brokerId by remember { mutableStateOf(vm.selected?.first?.id ?: brokers.first().id) }
    val broker = brokers.firstOrNull { it.id == brokerId } ?: brokers.first()
    var ports by remember { mutableStateOf<List<PortInfo>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current

    suspend fun reload() { loading = true; ports = withContext(Dispatchers.IO) { Net.ports(broker) } ?: emptyList(); loading = false }
    LaunchedEffect(broker.id) { reload() }

    Column(Modifier.fillMaxSize().background(pInk)) {
        // host picker + refresh
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                Row(Modifier.clickable { menuOpen = true }, verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Dns, null, tint = pAccent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(broker.name, color = Color.White, fontSize = 15.sp)
                    Icon(Icons.Filled.ArrowDropDown, null, tint = pDim)
                }
                DropdownMenu(menuOpen, onDismissRequest = { menuOpen = false }) {
                    brokers.forEach { b -> DropdownMenuItem(text = { Text(b.name) }, onClick = { brokerId = b.id; menuOpen = false }) }
                }
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { scope.launch { reload() } }) { Icon(Icons.Filled.Refresh, "Refresh", tint = pDim) }
        }
        Divider(color = Color(0xFF2A2B3C))

        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
            if (Forwards.active.isNotEmpty()) {
                item { SectionHeader("ACTIVE", Forwards.active.size) }
                items(Forwards.active, key = { it.id }) { af ->
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(8.dp).background(healthColor(af.health), RoundedCornerShape(4.dp)))
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(if (af.label.isNotEmpty()) af.label else "${af.brokerName}:${af.remotePort}", color = Color.White, fontSize = 14.sp)
                            Text("${af.brokerName}:${af.remotePort} → localhost:${af.localPort}  ·  ${af.health}",
                                color = pDim, fontSize = 11.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        TextButton(onClick = { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("http://localhost:${af.localPort}"))) }) {
                            Text("Open", color = pAccent)
                        }
                        IconButton(onClick = { Forwards.stop(af) }) { Icon(Icons.Filled.StopCircle, "Stop", tint = Color(0xFFF7768E)) }
                    }
                    Divider(color = Color(0xFF1E1F2B))
                }
            }

            item { SectionHeader("LISTENING ON ${broker.name.uppercase()}", -1) }
            if (loading && ports.isEmpty()) {
                item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = pAccent) } }
            } else if (ports.isEmpty()) {
                item { Text("No listening ports found.", color = pFaint, fontSize = 12.sp, modifier = Modifier.padding(vertical = 12.dp)) }
            } else {
                items(ports, key = { "${it.port}-${it.address}" }) { p ->
                    val forwarded = Forwards.active.any { it.brokerHost == broker.host && it.remotePort == p.port }
                    Row(
                        Modifier.fillMaxWidth().clickable(enabled = !forwarded) {
                            BatteryOpt.maybePrompt(ctx) // keep the tunnel alive in the background (esp. Samsung)
                            scope.launch {
                                val err = withContext(Dispatchers.IO) { Forwards.start(broker, p.port, p.process) }
                                if (err != null) error = err
                            }
                        }.padding(vertical = 9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("${p.port}", color = Color.White, fontSize = 14.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.width(64.dp))
                        Text(p.process.ifEmpty { p.address }, color = pDim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        if (forwarded) Text("forwarding", color = pLive, fontSize = 11.sp)
                        else Icon(Icons.Filled.ArrowForward, "Forward", tint = pFaint, modifier = Modifier.size(18.dp))
                    }
                    Divider(color = Color(0xFF1E1F2B))
                }
            }
        }
    }

    error?.let { msg ->
        AlertDialog(
            onDismissRequest = { error = null },
            title = { Text("Forward failed") },
            text = { Text(msg, color = pDim) },
            confirmButton = { TextButton(onClick = { error = null }) { Text("OK") } },
        )
    }
}

/** Dot color for a forward's live health: green=live, amber=connecting, red=broken. */
private fun healthColor(h: String) = when (h) {
    "live" -> pLive
    "broken" -> Color(0xFFF7768E)
    else -> Color(0xFFE0AF68)
}

@Composable
private fun SectionHeader(title: String, count: Int) {
    Row(Modifier.padding(top = 14.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = pFaint, fontSize = 11.sp, letterSpacing = 1.sp)
        if (count >= 0) {
            Spacer(Modifier.width(6.dp))
            Text("$count", color = pAccent, fontSize = 11.sp)
        }
    }
}
