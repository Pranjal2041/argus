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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Insights
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
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.CompositionLocalProvider
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

// Chrome colors resolve against the active theme (default Argus = the original look).
// @Composable getters so every existing `ink`/`panel`/… usage works unchanged and string
// literals like "waiting" are untouched.
private val ink: Color @Composable get() = LocalTheme.current.bg
private val panel: Color @Composable get() = LocalTheme.current.panel
private val accent: Color @Composable get() = LocalTheme.current.accent
private val waiting: Color @Composable get() = LocalTheme.current.waiting
private val unseenDot: Color @Composable get() = LocalTheme.current.unseen
private val bad: Color @Composable get() = LocalTheme.current.bad
private val cDim: Color @Composable get() = LocalTheme.current.dim
private val cFaint: Color @Composable get() = LocalTheme.current.faint
private val cBorder: Color @Composable get() = LocalTheme.current.border
private val cSel: Color @Composable get() = LocalTheme.current.selection
private val cText: Color @Composable get() = LocalTheme.current.text

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun App(vm: AppViewModel) {
    val th = vm.theme   // reading vm.themeId-backed state → recomposes the whole UI on switch
    CompositionLocalProvider(LocalTheme provides th) {
    MaterialTheme(colorScheme = if (th.isLight)
        lightColorScheme(primary = th.accent, background = th.bg, surface = th.panel)
    else darkColorScheme(primary = th.accent, background = th.bg, surface = th.panel)) {
        val drawerState = rememberDrawerState(DrawerValue.Open)
        val scope = rememberCoroutineScope()
        var showAdd by remember { mutableStateOf(false) }
        var showKey by remember { mutableStateOf(false) }
        var newSessionFor by remember { mutableStateOf<Broker?>(null) }
        var showAbout by remember { mutableStateOf(false) }
        var showTheme by remember { mutableStateOf(false) }
        var screen by remember { mutableStateOf(3) }   // 0 = terminal, 1 = files, 2 = ports, 3 = command center (home)
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
                    vm.refreshCC()   // pull the Mac-published statuses for the command center
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
                        onTheme = { showTheme = true },
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
                                    screen == 3 -> "Argus"
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
                                val sel = vm.selected!!
                                if (vm.hasWandb(sel.first, sel.second)) {
                                    IconButton(onClick = { vm.toggleWandb(sel.first, sel.second) }) {
                                        Icon(Icons.Filled.Insights, "W&B run",
                                            tint = if (vm.isWandbShown(sel.first, sel.second)) accent else cText)
                                    }
                                }
                                IconButton(onClick = { showFind = !showFind }) {
                                    Icon(Icons.Filled.Search, "Find", tint = if (showFind) accent else cText)
                                }
                                IconButton(onClick = { renderText = ActiveTerm.rt?.renderableText() }) {
                                    Icon(Icons.Filled.AutoAwesome, "Render", tint = cText)
                                }
                            }
                            IconButton(onClick = { screen = if (screen == 3) 0 else 3 }) {
                                Icon(Icons.Filled.GridView, "Command Center", tint = if (screen == 3) accent else cText)
                            }
                            IconButton(onClick = { screen = if (screen == 1) 0 else 1 }) {
                                Icon(if (screen == 1) Icons.Filled.Terminal else Icons.Filled.Folder,
                                    "Files", tint = if (screen == 1) accent else cText)
                            }
                            IconButton(onClick = { screen = if (screen == 2) 0 else 2 }) {
                                Icon(Icons.Filled.SettingsEthernet, "Ports", tint = if (screen == 2) accent else cText)
                            }
                            IconButton(onClick = { vm.refreshAll() }) { Icon(Icons.Filled.Refresh, "Refresh") }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(containerColor = panel, titleContentColor = cText),
                    )
                },
            ) { pad ->
                Box(Modifier.padding(pad).fillMaxSize().background(ink)) {
                    if (screen == 1) {
                        FilesScreen(vm)
                    } else if (screen == 2) {
                        PortsScreen(vm)
                    } else if (screen == 3) {
                        CommandCenterScreen(vm) { b, s -> vm.selected = b to s; screen = 0 }
                    } else {
                        val sel = vm.selected
                        if (sel == null) {
                            Text(
                                "Open the menu to add a broker and pick a session.",
                                color = cDim,
                                modifier = Modifier.align(Alignment.Center).padding(24.dp),
                            )
                        } else {
                            Column(Modifier.fillMaxSize()) {
                                if (showFind) FindBar(onClose = { showFind = false })
                                Box(Modifier.weight(1f)) {
                                    key(sel.first.id, sel.second) { TerminalScreen(vm, sel.first, sel.second) }
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
        if (showTheme) ThemePickerDialog(vm, onDismiss = { showTheme = false })
        newSessionFor?.let { b -> NewSessionDialog(b, vm, onDismiss = { newSessionFor = null }) }
    }
    }
}

@Composable
private fun ThemePickerDialog(vm: AppViewModel, onDismiss: () -> Unit) {
    val current = vm.themeId   // reading it → the dialog (and the app) recompose on switch
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done", color = accent) } },
        title = { Text("Theme", color = cText) },
        containerColor = panel,
        text = {
            LazyColumn(Modifier.heightIn(max = 480.dp)) {
                items(ThemePalette.all, key = { it.id }) { p ->
                    val selected = p.id == current
                    Row(
                        Modifier.fillMaxWidth()
                            .background(if (selected) accent.copy(alpha = 0.16f) else Color.Transparent, RoundedCornerShape(10.dp))
                            .clickable { vm.selectTheme(p.id) }
                            .padding(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        // swatch rendered in THIS theme's own colors
                        Row(
                            Modifier.background(p.bg, RoundedCornerShape(7.dp)).padding(6.dp),
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            listOf(p.accent, p.milestone, p.working, p.waiting, p.unseen, p.bad).forEach {
                                Box(Modifier.size(9.dp).background(it, RoundedCornerShape(5.dp)))
                            }
                        }
                        Spacer(Modifier.width(12.dp))
                        Text(p.name, color = cText, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        if (selected) Icon(Icons.Filled.Check, null, tint = accent, modifier = Modifier.size(18.dp))
                    }
                }
            }
        },
    )
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
                    color = cText, fontSize = 14.sp,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Reach every claude session across your Mac, clusters, Windows, and phone — terminals, ports, and files — over Tailscale, peer-to-peer. No central server.",
                    color = cDim, fontSize = 13.sp,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Named for Argus Panoptes, the hundred-eyed watcher.",
                    color = cFaint, fontSize = 11.sp,
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
                    fontSize = 13.sp, color = cDim,
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = key, onValueChange = { key = it }, singleLine = true, placeholder = { Text("tskey-auth-…") })
                Text("status: ${vm.engineStatus}", color = cDim, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
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
    onTheme: () -> Unit,
) {
    Column(Modifier.fillMaxSize().padding(top = 12.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f).clickable(onClick = onAbout)) {
                Text("Argus", color = cText, fontSize = 18.sp)
                Text("tailnet: ${vm.engineStatus}", color = cFaint, fontSize = 11.sp, maxLines = 1)
            }
            IconButton(onClick = onTheme) { Icon(Icons.Filled.Palette, "Theme", tint = cDim) }
            IconButton(onClick = onAbout) { Icon(Icons.Filled.Info, "About", tint = cFaint) }
            IconButton(onClick = onAuthKey) { Icon(Icons.Filled.VpnKey, "Tailnet key", tint = cDim) }
            IconButton(onClick = onAddBroker) { Icon(Icons.Filled.Add, "Add broker", tint = accent) }
        }
        Divider(color = cBorder)
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
                            Text(s.name, color = cText, fontSize = 14.sp, maxLines = 1)
                            Text(b.name, color = cFaint, fontSize = 11.sp, maxLines = 1)
                        }
                    }
                }
            }
            Divider(color = cBorder)
        }

        // Agent (ut spawn) sessions are background jobs — hidden by default, with this
        // toggle to reveal them. They auto-clean when left idle.
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 4.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Show agent sessions", color = cDim, fontSize = 12.sp, modifier = Modifier.weight(1f))
            Switch(
                checked = vm.showAgentSessions,
                onCheckedChange = { vm.showAgentSessions = it },
                modifier = Modifier.scale(0.8f),
            )
        }
        // "Show hidden" — reveal user-hidden sessions so they can be restored. Only shown
        // when at least one session is hidden (avoids clutter when nothing is hidden).
        val anyHidden = vm.brokers.any { brk -> vm.sessions[brk.id].orEmpty().any { it.hidden } }
        if (anyHidden) {
            Row(
                Modifier.fillMaxWidth().padding(start = 16.dp, end = 10.dp, top = 0.dp, bottom = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Show hidden", color = cDim, fontSize = 12.sp, modifier = Modifier.weight(1f))
                Switch(checked = vm.showHidden, onCheckedChange = { vm.showHidden = it }, modifier = Modifier.scale(0.8f))
            }
        }
        val brokerList = vm.brokers.toList()
        // Read sessions + the visibility toggles HERE (composable body) and pass the
        // builder a plain pre-filtered map: reading these transitively inside the
        // LazyColumn item builder did not reliably re-run it (same lesson as attention).
        val showAgent = vm.showAgentSessions
        val showHidden = vm.showHidden
        val visibleByBroker = brokerList.associate { brk ->
            brk.id to vm.sessions[brk.id].orEmpty().filter { (showAgent || !it.agent) && (showHidden || !it.hidden) }
        }
        LazyColumn(Modifier.weight(1f)) {
            items(brokerList, key = { it.id }) { b ->
                Row(
                    Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 12.dp, bottom = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(b.name, color = accent, fontSize = 13.sp, modifier = Modifier.weight(1f))
                    IconButton(onClick = { onNewSession(b) }) { Icon(Icons.Filled.Add, "New session", tint = cDim) }
                    IconButton(onClick = { vm.removeBroker(b) }) { Icon(Icons.Filled.Delete, "Remove", tint = cFaint) }
                }
                val list = visibleByBroker[b.id].orEmpty()
                if (list.isEmpty()) {
                    Text("no sessions", color = cFaint, fontSize = 12.sp,
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
                                .background(if (active) cSel else Color.Transparent)
                                .padding(start = 24.dp, end = 16.dp, top = 8.dp, bottom = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(8.dp).background(
                                when {
                                    s.state == "working" -> accent
                                    vm.isUnseen(b, s.name) -> unseenDot
                                    s.state == "waiting" -> waiting
                                    else -> cFaint
                                },
                                RoundedCornerShape(4.dp),
                            ))
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text(s.name, color = cText, fontSize = 14.sp, maxLines = 1)
                                if (s.path.isNotEmpty())
                                    Text(s.path, color = cFaint, fontSize = 11.sp, maxLines = 1)
                            }
                        }
                    }
                }
            }
            if (vm.brokers.isEmpty()) {
                item {
                    Text(
                        "No brokers yet. Tap + to add one by its tailnet hostname.",
                        color = cDim, fontSize = 13.sp,
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
                    fontSize = 13.sp, color = cDim)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, label = { Text("name") })
                Spacer(Modifier.height(4.dp))
                TextButton(onClick = { vm.setHidden(b, s.name, !s.hidden); onDismiss() }) {
                    Text(if (s.hidden) "Restore panel (unhide)" else "Hide panel", color = accent)
                }
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
private fun TerminalScreen(vm: AppViewModel, broker: Broker, session: String) {
    val context = LocalContext.current
    val rt = remember(broker.id, session) {
        RemoteTerminal(context, broker, session).also {
            ActiveTerm.rt = it
            it.onWandbRuns = { runs -> vm.mergeWandb(vm.wandbKey(broker, session), runs) }
        }
    }
    val theme = LocalTheme.current
    LaunchedEffect(rt, theme.id) { rt.applyTheme(theme) }   // recolor the terminal on open + theme switch
    DisposableEffect(rt) {
        onDispose {
            if (ActiveTerm.rt === rt) ActiveTerm.rt = null
            rt.close()
        }
    }

    // Show the W&B run in place of the terminal when toggled on — the RemoteTerminal stays
    // alive (remember), so its connection + detection keep running underneath.
    if (vm.isWandbShown(broker, session) && vm.currentWandbRun(broker, session) != null) {
        WandbScreen(vm, broker, session, onClose = { vm.hideWandb(broker, session) })
    } else {
        Column(Modifier.fillMaxSize()) {
            AndroidView(
                factory = { rt.view },
                modifier = Modifier.weight(1f).fillMaxWidth().background(Color.Black),
            )
            AccessoryKeys(onBytes = { rt.sendBytes(it) }, onKeyboard = { rt.showKeyboard() })
        }
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
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp, color = cText),
        )
        Text(
            if (query.isEmpty()) "" else if (matches.isEmpty()) "0" else "${cur + 1}/${matches.size}",
            color = if (matches.isEmpty() && query.isNotEmpty()) waiting else cDim,
            fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp),
        )
        TextButton(onClick = { jump(-1) }) { Text("↑", fontSize = 16.sp) }
        TextButton(onClick = { jump(1) }) { Text("↓", fontSize = 16.sp) }
        IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Close find", tint = cFaint) }
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
                    .background(cSel, RoundedCornerShape(8.dp))
                    .clickable { onBytes(bytes) },
                contentAlignment = Alignment.Center,
            ) { Text(label, color = cText, fontFamily = FontFamily.Monospace, fontSize = 15.sp) }
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
                Text("Tailnet hostname of a node running the broker.", fontSize = 13.sp, color = cDim)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = host, onValueChange = { host = it }, singleLine = true,
                    placeholder = { Text("ut-host.your-tailnet.ts.net") },
                )
                vm.lastError?.let { Text(it, color = bad, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp)) }
                if (vm.busy) Text("probing…", color = cDim, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
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
