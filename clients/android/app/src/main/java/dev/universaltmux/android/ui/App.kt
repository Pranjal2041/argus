package dev.universaltmux.android

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SettingsEthernet
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.VpnKey
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val ink = Color(0xFF1A1B26)
private val panel = Color(0xFF16161E)
private val accent = Color(0xFF7AA2F7)
private val waiting = Color(0xFFE0AF68)
private val unseenDot = Color(0xFFFF9F40)   // orange — agent finished a turn, not yet viewed
private val bad = Color(0xFFF7768E)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun App(vm: AppViewModel) {
    MaterialTheme(colorScheme = darkColorScheme(primary = accent, background = ink, surface = panel)) {
        val drawerState = rememberDrawerState(DrawerValue.Open)
        val scope = rememberCoroutineScope()
        var showAdd by remember { mutableStateOf(false) }
        var showKey by remember { mutableStateOf(false) }
        var newSessionFor by remember { mutableStateOf<Broker?>(null) }
        var showAbout by remember { mutableStateOf(false) }
        var screen by remember { mutableStateOf(0) }   // 0 = terminal, 1 = files, 2 = ports
        var showFind by remember { mutableStateOf(false) }
        var renderText by remember { mutableStateOf<String?>(null) }  // non-nil → Renders overlay

        // Continuously refresh sessions WHILE THE APP IS IN THE FOREGROUND so a missed or
        // slow poll self-heals instead of leaving the list frozen/missing (the previous
        // behavior — refresh only on launch + the manual button). repeatOnLifecycle stops
        // the loop when backgrounded, so it doesn't drain battery. Known brokers are
        // refreshed every 3s; a full re-discovery runs roughly every 15s.
        val lifecycleOwner = LocalLifecycleOwner.current
        LaunchedEffect(Unit) {
            lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                var tick = 0
                while (true) {
                    if (TsnetCore.isUp && tick % 5 == 0) vm.refreshAll() else vm.pollKnown()
                    tick++
                    delay(3000)
                }
            }
        }

        ModalNavigationDrawer(
            drawerState = drawerState,
            // Only allow the swipe gesture while the drawer is already open (to swipe it
            // closed). When closed, the edge-swipe is off so it can't hijack terminal
            // scrolling or pop open mid-scroll — open it with the top-left menu button.
            gesturesEnabled = drawerState.isOpen,
            drawerContent = {
                ModalDrawerSheet(drawerContainerColor = panel) {
                    Sidebar(
                        vm = vm,
                        onSelect = { b, s -> vm.selected = b to s; scope.launch { drawerState.close() } },
                        onAddBroker = { showAdd = true },
                        onNewSession = { newSessionFor = it },
                        onAuthKey = { showKey = true },
                        onAbout = { showAbout = true },
                    )
                }
            },
        ) {
            Scaffold(
                containerColor = ink,
                topBar = {
                    TopAppBar(
                        title = {
                            val sel = vm.selected
                            Text(
                                when {
                                    screen == 1 -> "Files"
                                    screen == 2 -> "Ports"
                                    sel != null -> "${sel.second}  ·  ${sel.first.name}"
                                    else -> "Argus"
                                },
                                maxLines = 1,
                            )
                        },
                        navigationIcon = {
                            IconButton(onClick = { scope.launch { drawerState.open() } }) {
                                Icon(Icons.Filled.Menu, "Sessions")
                            }
                        },
                        actions = {
                            if (screen == 0 && vm.selected != null) {
                                IconButton(onClick = { showFind = !showFind }) {
                                    Icon(Icons.Filled.Search, "Find", tint = if (showFind) accent else Color.White)
                                }
                                IconButton(onClick = { renderText = ActiveTerm.rt?.renderableText() }) {
                                    Icon(Icons.Filled.AutoAwesome, "Render", tint = Color.White)
                                }
                            }
                            IconButton(onClick = { screen = if (screen == 1) 0 else 1 }) {
                                Icon(if (screen == 1) Icons.Filled.Terminal else Icons.Filled.Folder,
                                    "Files", tint = if (screen == 1) accent else Color.White)
                            }
                            IconButton(onClick = { screen = if (screen == 2) 0 else 2 }) {
                                Icon(Icons.Filled.SettingsEthernet, "Ports", tint = if (screen == 2) accent else Color.White)
                            }
                            IconButton(onClick = { vm.refreshAll() }) { Icon(Icons.Filled.Refresh, "Refresh") }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(containerColor = panel, titleContentColor = Color.White),
                    )
                },
            ) { pad ->
                Box(Modifier.padding(pad).fillMaxSize().background(ink)) {
                    if (screen == 1) {
                        FilesScreen(vm)
                    } else if (screen == 2) {
                        PortsScreen(vm)
                    } else {
                        val sel = vm.selected
                        if (sel == null) {
                            Text(
                                "Open the menu to add a broker and pick a session.",
                                color = Color(0xFF9AA5CE),
                                modifier = Modifier.align(Alignment.Center).padding(24.dp),
                            )
                        } else {
                            Column(Modifier.fillMaxSize()) {
                                if (showFind) FindBar(onClose = { showFind = false })
                                Box(Modifier.weight(1f)) {
                                    key(sel.first.id, sel.second) { TerminalScreen(sel.first, sel.second) }
                                }
                            }
                        }
                        renderText?.let { md -> RenderOverlay(md, onClose = { renderText = null }) }
                    }
                }
            }
        }

        if (showAdd) AddBrokerDialog(vm, onDismiss = { showAdd = false })
        if (showKey) AuthKeyDialog(vm, onDismiss = { showKey = false })
        if (showAbout) AboutDialog(onDismiss = { showAbout = false })
        newSessionFor?.let { b -> NewSessionDialog(b, vm, onDismiss = { newSessionFor = null }) }
    }
}

@Composable
private fun AboutDialog(onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Argus") },
        text = {
            Column {
                Text(
                    "One watchful eye over every coding agent, on every machine.",
                    color = Color.White, fontSize = 14.sp,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Reach every claude session across your Mac, clusters, Windows, and phone — terminals, ports, and files — over Tailscale, peer-to-peer. No central server.",
                    color = Color(0xFF9AA5CE), fontSize = 13.sp,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Named for Argus Panoptes, the hundred-eyed watcher.",
                    color = Color(0xFF565F89), fontSize = 11.sp,
                )
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

@Composable
private fun AuthKeyDialog(vm: AppViewModel, onDismiss: () -> Unit) {
    var key by remember { mutableStateOf(vm.authKey) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Tailnet key") },
        text = {
            Column {
                Text(
                    "Paste a Tailscale auth key. The app joins your tailnet itself and auto-discovers brokers — no Tailscale app or manual hostnames needed.",
                    fontSize = 13.sp, color = Color(0xFF9AA5CE),
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = key, onValueChange = { key = it }, singleLine = true, placeholder = { Text("tskey-auth-…") })
                Text("status: ${vm.engineStatus}", color = Color(0xFF9AA5CE), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
            }
        },
        confirmButton = { TextButton(onClick = { vm.joinTailnet(key); onDismiss() }) { Text("Join & discover") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

@Composable
private fun Sidebar(
    vm: AppViewModel,
    onSelect: (Broker, String) -> Unit,
    onAddBroker: () -> Unit,
    onNewSession: (Broker) -> Unit,
    onAuthKey: () -> Unit,
    onAbout: () -> Unit,
) {
    Column(Modifier.fillMaxSize().padding(top = 12.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f).clickable(onClick = onAbout)) {
                Text("Argus", color = Color.White, fontSize = 18.sp)
                Text("tailnet: ${vm.engineStatus}", color = Color(0xFF565F89), fontSize = 11.sp, maxLines = 1)
            }
            IconButton(onClick = onAbout) { Icon(Icons.Filled.Info, "About", tint = Color(0xFF565F89)) }
            IconButton(onClick = onAuthKey) { Icon(Icons.Filled.VpnKey, "Tailnet key", tint = Color(0xFF9AA5CE)) }
            IconButton(onClick = onAddBroker) { Icon(Icons.Filled.Add, "Add broker", tint = accent) }
        }
        Divider(color = Color(0xFF2A2B3C))
        var menuFor by remember { mutableStateOf<Pair<Broker, SessionInfo>?>(null) }

        // PINNED "Needs attention": sessions blocked on you, across all brokers,
        // each with inline steering. Lives ABOVE the scrolling list (not as its
        // first items) so it is ALWAYS visible — it's the whole point of the
        // phone, and burying it at the top of a scroll defeated that. Capped +
        // independently scrollable so a flood of prompts can't push the broker
        // list off-screen. Read in the composable body (restartable scope) so it
        // appears the instant a session starts waiting.
        val attn = vm.attention.toList()
        if (attn.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("NEEDS ATTENTION", color = waiting, fontSize = 11.sp)
                Spacer(Modifier.weight(1f))
                Text("${attn.size}", color = ink, fontSize = 11.sp,
                    modifier = Modifier.background(waiting, RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 1.dp))
            }
            Column(Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                attn.forEach { (b, s) ->
                    Row(
                        Modifier.fillMaxWidth()
                            .clickable { onSelect(b, s.name) }
                            .background(waiting.copy(alpha = 0.07f))
                            .padding(start = 16.dp, end = 10.dp, top = 8.dp, bottom = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(8.dp).background(waiting, RoundedCornerShape(4.dp)))
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(s.name, color = Color.White, fontSize = 14.sp, maxLines = 1)
                            Text(b.name, color = Color(0xFF565F89), fontSize = 11.sp, maxLines = 1)
                        }
                    }
                }
            }
            Divider(color = Color(0xFF2A2B3C))
        }

        // Agent (ut spawn) sessions are background jobs — hidden by default, with this
        // toggle to reveal them. They auto-clean when left idle.
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 4.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Show agent sessions", color = Color(0xFF9AA5CE), fontSize = 12.sp, modifier = Modifier.weight(1f))
            Switch(
                checked = vm.showAgentSessions,
                onCheckedChange = { vm.showAgentSessions = it },
                modifier = Modifier.scale(0.8f),
            )
        }
        val brokerList = vm.brokers.toList()
        // Read sessions + the agent-visibility toggle HERE (composable body) and pass
        // the builder a plain pre-filtered map: reading these transitively inside the
        // LazyColumn item builder did not reliably re-run it (same lesson as attention).
        val showAgent = vm.showAgentSessions
        val visibleByBroker = brokerList.associate { brk ->
            brk.id to vm.sessions[brk.id].orEmpty().filter { showAgent || !it.agent }
        }
        LazyColumn(Modifier.weight(1f)) {
            items(brokerList, key = { it.id }) { b ->
                Row(
                    Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(b.name, color = accent, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    IconButton(onClick = { onNewSession(b) }) { Icon(Icons.Filled.Add, "New session", tint = Color(0xFF9AA5CE)) }
                    IconButton(onClick = { vm.removeBroker(b) }) { Icon(Icons.Filled.Delete, "Remove", tint = Color(0xFF565F89)) }
                }
                val list = visibleByBroker[b.id].orEmpty()
                if (list.isEmpty()) {
                    Text("no sessions", color = Color(0xFF565F89), fontSize = 12.sp,
                        modifier = Modifier.padding(start = 24.dp, bottom = 6.dp))
                } else {
                    list.forEach { s ->
                        val sel = vm.selected
                        val active = sel?.first?.id == b.id && sel.second == s.name
                        @OptIn(ExperimentalFoundationApi::class)
                        Row(
                            Modifier.fillMaxWidth()
                                .combinedClickable(
                                    onClick = { onSelect(b, s.name) },
                                    onLongClick = { menuFor = b to s },  // rename / kill
                                )
                                .background(if (active) Color(0xFF24283B) else Color.Transparent)
                                .padding(start = 24.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(8.dp).background(
                                when {
                                    s.state == "working" -> accent
                                    vm.isUnseen(b, s.name) -> unseenDot
                                    s.state == "waiting" -> waiting
                                    else -> Color(0xFF565F89)
                                },
                                RoundedCornerShape(4.dp),
                            ))
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(s.name, color = Color.White, fontSize = 14.sp, maxLines = 1)
                                if (s.path.isNotEmpty())
                                    Text(s.path, color = Color(0xFF565F89), fontSize = 11.sp, maxLines = 1)
                            }
                        }
                    }
                }
            }
            if (vm.brokers.isEmpty()) {
                item {
                    Text(
                        "No brokers yet. Tap + to add one by its tailnet hostname.",
                        color = Color(0xFF9AA5CE), fontSize = 13.sp,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }
        }
        menuFor?.let { (b, s) -> SessionMenuDialog(vm, b, s, onDismiss = { menuFor = null }) }
    }
}

/** Long-press menu for a session row: rename in place, or kill. */
@Composable
private fun SessionMenuDialog(vm: AppViewModel, b: Broker, s: SessionInfo, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf(s.name) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(s.name) },
        text = {
            Column {
                Text("Rename the session, or kill it (ends everything running in it).",
                    fontSize = 13.sp, color = Color(0xFF9AA5CE))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, label = { Text("name") })
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val to = name.trim()
                    if (to.isNotEmpty() && to != s.name) vm.rename(b, s.name, to)
                    onDismiss()
                },
                enabled = name.trim().isNotEmpty(),
            ) { Text("Rename") }
        },
        dismissButton = {
            Row {
                TextButton(onClick = { vm.kill(b, s.name); onDismiss() }) { Text("Kill", color = bad) }
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun TerminalScreen(broker: Broker, session: String) {
    val context = LocalContext.current
    val rt = remember(broker.id, session) { RemoteTerminal(context, broker, session).also { ActiveTerm.rt = it } }
    DisposableEffect(rt) {
        onDispose {
            if (ActiveTerm.rt === rt) ActiveTerm.rt = null
            rt.close()
        }
    }

    Column(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { rt.view },
            modifier = Modifier.weight(1f).fillMaxWidth().background(Color.Black),
        )
        AccessoryKeys(onBytes = { rt.sendBytes(it) }, onKeyboard = { rt.showKeyboard() })
    }
}

/** Find-in-terminal: searches the transcript buffer, jumps between match rows. */
@Composable
fun FindBar(onClose: () -> Unit) {
    var query by remember { mutableStateOf("") }
    var matches by remember { mutableStateOf(listOf<Int>()) }
    var cur by remember { mutableStateOf(0) }
    fun search(q: String) {
        query = q
        matches = ActiveTerm.rt?.findRows(q) ?: emptyList()
        cur = matches.size - 1  // start from the most recent match
        if (matches.isNotEmpty()) ActiveTerm.rt?.scrollToBufferRow(matches[cur])
    }
    fun jump(delta: Int) {
        if (matches.isEmpty()) return
        cur = (cur + delta + matches.size) % matches.size
        ActiveTerm.rt?.scrollToBufferRow(matches[cur])
    }
    Row(
        Modifier.fillMaxWidth().background(panel).padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = query, onValueChange = { search(it) }, singleLine = true,
            placeholder = { Text("Find", fontSize = 13.sp) },
            modifier = Modifier.weight(1f).height(52.dp),
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp, color = Color.White),
        )
        Text(
            if (query.isEmpty()) "" else if (matches.isEmpty()) "0" else "${cur + 1}/${matches.size}",
            color = if (matches.isEmpty() && query.isNotEmpty()) waiting else Color(0xFF9AA5CE),
            fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp),
        )
        TextButton(onClick = { jump(-1) }) { Text("↑", fontSize = 16.sp) }
        TextButton(onClick = { jump(1) }) { Text("↓", fontSize = 16.sp) }
        IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close find", tint = Color(0xFF565F89)) }
    }
}

@Composable
private fun AccessoryKeys(onBytes: (ByteArray) -> Unit, onKeyboard: () -> Unit) {
    val keys = listOf(
        "esc" to byteArrayOf(27),
        "tab" to byteArrayOf(9),
        "^C" to byteArrayOf(3),
        "^Z" to byteArrayOf(26),
        "↑" to byteArrayOf(27, 91, 65),
        "↓" to byteArrayOf(27, 91, 66),
        "←" to byteArrayOf(27, 91, 68),
        "→" to byteArrayOf(27, 91, 67),
        "/" to byteArrayOf('/'.code.toByte()),
        "|" to byteArrayOf('|'.code.toByte()),
        "~" to byteArrayOf('~'.code.toByte()),
        "-" to byteArrayOf('-'.code.toByte()),
    )
    Row(
        Modifier.fillMaxWidth().background(panel).horizontalScroll(rememberScrollState())
            .padding(horizontal = 6.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onKeyboard) { Text("⌨", color = accent, fontSize = 18.sp) }
        keys.forEach { (label, bytes) ->
            Box(
                Modifier.padding(horizontal = 3.dp).size(width = 46.dp, height = 38.dp)
                    .background(Color(0xFF24283B), RoundedCornerShape(8.dp))
                    .clickable { onBytes(bytes) },
                contentAlignment = Alignment.Center,
            ) { Text(label, color = Color.White, fontFamily = FontFamily.Monospace, fontSize = 15.sp) }
        }
    }
}

@Composable
private fun AddBrokerDialog(vm: AppViewModel, onDismiss: () -> Unit) {
    var host by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add broker") },
        text = {
            Column {
                Text("Tailnet hostname of a node running the broker.", fontSize = 13.sp, color = Color(0xFF9AA5CE))
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = host, onValueChange = { host = it }, singleLine = true,
                    placeholder = { Text("ut-host.your-tailnet.ts.net") },
                )
                vm.lastError?.let { Text(it, color = Color(0xFFF7768E), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp)) }
                if (vm.busy) Text("probing…", color = Color(0xFF9AA5CE), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
            }
        },
        confirmButton = { TextButton(onClick = { vm.addBroker(host); if (!vm.busy) onDismiss() }) { Text("Add") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

@Composable
private fun NewSessionDialog(broker: Broker, vm: AppViewModel, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("New session on ${broker.name}") },
        text = {
            OutlinedTextField(
                value = name, onValueChange = { name = it }, singleLine = true,
                placeholder = { Text("session name") },
            )
        },
        confirmButton = {
            TextButton(onClick = { if (name.isNotBlank()) { vm.create(broker, name.trim(), null); onDismiss() } }) { Text("Create") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
