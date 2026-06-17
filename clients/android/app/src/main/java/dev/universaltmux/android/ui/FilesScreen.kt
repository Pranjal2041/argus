package dev.universaltmux.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

private val fInk: Color @Composable get() = LocalTheme.current.bgDeep
private val fPanel: Color @Composable get() = LocalTheme.current.panel
private val fAccent: Color @Composable get() = LocalTheme.current.accent
private val fDim: Color @Composable get() = LocalTheme.current.dim
private val fFaint: Color @Composable get() = LocalTheme.current.faint
private val fText: Color @Composable get() = LocalTheme.current.text
private val fBorder: Color @Composable get() = LocalTheme.current.border
private val fBad: Color @Composable get() = LocalTheme.current.bad
private val fPanelAlt: Color @Composable get() = LocalTheme.current.panelAlt

private enum class Kind { TEXT, IMAGE, PDF, BINARY }
private class OpenFile(
    val path: String, val name: String, val kind: Kind,
    val text: String? = null, val image: Bitmap? = null, val pages: List<Bitmap>? = null,
)

/** Per-host browsing state (single-directory navigation, mobile-style). */
private class FilesController(var broker: Broker, val ctx: Context) {
    var path by mutableStateOf("")
    var sep = "/"
    var entries by mutableStateOf<List<FileEntry>>(emptyList())
    var loading by mutableStateOf(false)
    var open by mutableStateOf<OpenFile?>(null)
    var uploading by mutableStateOf<Pair<String, Float>?>(null)   // (name, 0..1)
    var downloading by mutableStateOf<Pair<String, Float>?>(null)

    suspend fun start() {
        val h = withContext(Dispatchers.IO) { Net.fsHome(broker) }
        if (h != null) { sep = h.sep; go(h.home) } else go("")
    }
    suspend fun go(p: String) {
        loading = true
        val list = withContext(Dispatchers.IO) { Net.fsList(broker, p) }
        loading = false
        if (list != null) {
            path = p
            entries = list.sortedWith(compareByDescending<FileEntry> { it.isDir }.thenBy { it.name.lowercase() })
        }
    }
    suspend fun up() = go(parent(path))

    suspend fun openEntry(e: FileEntry) {
        if (e.isDir) { go(e.path); return }
        when (kindOf(e.name)) {
            Kind.IMAGE -> {
                val bytes = withContext(Dispatchers.IO) { Net.fsReadBytes(broker, e.path) }
                val bmp = bytes?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }
                open = OpenFile(e.path, e.name, if (bmp != null) Kind.IMAGE else Kind.BINARY, image = bmp)
            }
            Kind.PDF -> {
                val bytes = withContext(Dispatchers.IO) { Net.fsReadBytes(broker, e.path) }
                val pages = bytes?.let { withContext(Dispatchers.Default) { renderPdf(ctx, it) } }
                open = OpenFile(e.path, e.name, if (!pages.isNullOrEmpty()) Kind.PDF else Kind.BINARY, pages = pages)
            }
            Kind.TEXT -> {
                if (e.size > 5_000_000) { open = OpenFile(e.path, e.name, Kind.BINARY); return }
                val bytes = withContext(Dispatchers.IO) { Net.fsReadBytes(broker, e.path) }
                val text = bytes?.let { runCatching { it.toString(Charsets.UTF_8) }.getOrNull() }
                open = if (text != null) OpenFile(e.path, e.name, Kind.TEXT, text = text)
                       else OpenFile(e.path, e.name, Kind.BINARY)
            }
            Kind.BINARY -> open = OpenFile(e.path, e.name, Kind.BINARY)
        }
    }

    suspend fun save(path: String, text: String): Boolean =
        withContext(Dispatchers.IO) { Net.fsWrite(broker, path, text.toByteArray(Charsets.UTF_8)) }
    suspend fun mkdir(name: String) { if (withContext(Dispatchers.IO) { Net.fsMkdir(broker, joined(path, name)) }) go(path) }
    suspend fun rename(e: FileEntry, name: String) {
        if (withContext(Dispatchers.IO) { Net.fsRename(broker, e.path, joined(parent(e.path), name)) }) go(path)
    }
    suspend fun delete(e: FileEntry) { if (withContext(Dispatchers.IO) { Net.fsDelete(broker, e.path) }) go(path) }
    suspend fun upload(uri: Uri) {
        val bytes = withContext(Dispatchers.IO) { runCatching { ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull() } ?: return
        val name = displayName(ctx, uri)
        uploading = name to 0f
        val ok = withContext(Dispatchers.IO) {
            Net.fsWrite(broker, joined(path, name), bytes) { sent, total ->
                uploading = name to (if (total > 0) sent.toFloat() / total else 0f)
            }
        }
        uploading = null
        if (ok) go(path)
    }
    suspend fun downloadTo(srcPath: String, name: String, dest: Uri) {
        downloading = name to 0f
        withContext(Dispatchers.IO) {
            runCatching {
                ctx.contentResolver.openOutputStream(dest)?.use { out ->
                    Net.fsDownloadTo(broker, srcPath, out) { read, total ->
                        downloading = name to (if (total > 0) read.toFloat() / total else 0f)
                    }
                }
            }
        }
        downloading = null
    }

    fun joined(parent: String, name: String) = if (parent.endsWith(sep)) parent + name else parent + sep + name
    fun parent(p: String): String {
        var s = p
        while (s.length > 1 && s.endsWith(sep)) s = s.dropLast(sep.length)
        val i = s.lastIndexOf(sep)
        if (i < 0) return ""
        val par = s.substring(0, i)
        return if (par.isEmpty()) sep else if (!par.contains(sep)) par + sep else par
    }
    private fun kindOf(name: String): Kind {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext in setOf("png", "jpg", "jpeg", "gif", "bmp", "webp", "heic")) return Kind.IMAGE
        if (ext == "pdf") return Kind.PDF
        if (ext in setOf("zip", "tar", "gz", "tgz", "xz", "7z", "rar", "mp4", "mov", "mp3", "wav", "so", "bin", "o", "a", "dylib", "exe", "dll", "jar", "class", "pyc"))
            return Kind.BINARY
        return Kind.TEXT
    }
}

@Composable
fun FilesScreen(vm: AppViewModel) {
    val brokers = vm.brokers
    if (brokers.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("No hosts yet — add a broker first.", color = fDim) }
        return
    }
    val ctx = LocalContext.current
    var brokerId by remember { mutableStateOf(vm.selected?.first?.id ?: brokers.first().id) }
    val broker = brokers.firstOrNull { it.id == brokerId } ?: brokers.first()
    val ctrl = remember(broker.id) { FilesController(broker, ctx) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(broker.id) { ctrl.start() }

    // download (Storage Access Framework) — keeps the source path until the user picks a destination
    var pendingDownload by remember { mutableStateOf<Pair<String, String>?>(null) }
    val downloadLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val pd = pendingDownload; pendingDownload = null
        if (uri != null && pd != null) scope.launch { ctrl.downloadTo(pd.first, pd.second, uri) }
    }
    fun download(path: String, name: String) { pendingDownload = path to name; downloadLauncher.launch(name) }

    val uploadLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch { ctrl.upload(uri) }
    }

    val open = ctrl.open
    if (open != null) {
        FileViewer(open, onBack = { ctrl.open = null },
            onSave = { text -> scope.launch { ctrl.save(open.path, text) } },
            onDownload = { download(open.path, open.name) })
        return
    }

    var menuOpen by remember { mutableStateOf(false) }
    var showNewFolder by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<FileEntry?>(null) }
    var deleteTarget by remember { mutableStateOf<FileEntry?>(null) }
    var searching by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    LaunchedEffect(ctrl.path) { search = "" }   // filter is depth-1: reset it when the folder changes

    Column(Modifier.fillMaxSize().background(fInk)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                Row(Modifier.clickable { menuOpen = true }, verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Dns, null, tint = fAccent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(broker.name, color = fText, fontSize = 15.sp)
                    Icon(Icons.Filled.ArrowDropDown, null, tint = fDim)
                }
                DropdownMenu(menuOpen, onDismissRequest = { menuOpen = false }) {
                    brokers.forEach { b -> DropdownMenuItem(text = { Text(b.name) }, onClick = { brokerId = b.id; menuOpen = false }) }
                }
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { searching = !searching; if (!searching) search = "" }) {
                Icon(Icons.Filled.Search, "Search", tint = if (searching) fAccent else fDim)
            }
            IconButton(onClick = { uploadLauncher.launch(arrayOf("*/*")) }) { Icon(Icons.Filled.Upload, "Upload", tint = fDim) }
            IconButton(onClick = { showNewFolder = true }) { Icon(Icons.Filled.CreateNewFolder, "New folder", tint = fDim) }
            IconButton(onClick = { scope.launch { ctrl.go(ctrl.path) } }) { Icon(Icons.Filled.Refresh, "Refresh", tint = fDim) }
        }
        Divider(color = fBorder)
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { scope.launch { ctrl.up() } }, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Filled.ArrowUpward, "Up", tint = fDim, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(8.dp))
            Text(ctrl.path.ifEmpty { "Computer" }, color = fDim, fontSize = 12.sp,
                fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Divider(color = fBorder)

        if (searching) {
            OutlinedTextField(
                value = search, onValueChange = { search = it }, singleLine = true,
                placeholder = { Text("Filter this folder") },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
        ctrl.uploading?.let { (n, p) -> TransferBanner("Uploading", n, p) }
        ctrl.downloading?.let { (n, p) -> TransferBanner("Downloading", n, p) }

        val shown = if (search.isBlank()) ctrl.entries else ctrl.entries.filter { it.name.contains(search, ignoreCase = true) }
        if (ctrl.loading && ctrl.entries.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = fAccent) }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(shown, key = { it.path }) { e ->
                    var rowMenu by remember { mutableStateOf(false) }
                    Row(
                        Modifier.fillMaxWidth().clickable { scope.launch { ctrl.openEntry(e) } }
                            .padding(horizontal = 14.dp, vertical = 11.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(if (e.isDir) Icons.Filled.Folder else Icons.Filled.InsertDriveFile, null,
                            tint = if (e.isDir) fAccent else fDim, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(12.dp))
                        Text(e.name, color = fText.copy(alpha = 0.9f), fontSize = 14.sp,
                            maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        if (!e.isDir) Text(byteSize(e.size), color = fFaint, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                        Box {
                            IconButton(onClick = { rowMenu = true }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Filled.MoreVert, "More", tint = fFaint, modifier = Modifier.size(18.dp))
                            }
                            DropdownMenu(rowMenu, onDismissRequest = { rowMenu = false }) {
                                DropdownMenuItem(text = { Text("Open") }, onClick = { rowMenu = false; scope.launch { ctrl.openEntry(e) } })
                                if (!e.isDir) DropdownMenuItem(text = { Text("Download") }, onClick = { rowMenu = false; download(e.path, e.name) })
                                DropdownMenuItem(text = { Text("Rename…") }, onClick = { rowMenu = false; renameTarget = e })
                                DropdownMenuItem(text = { Text("Delete", color = fBad) }, onClick = { rowMenu = false; deleteTarget = e })
                            }
                        }
                    }
                    Divider(color = fPanelAlt)
                }
            }
        }
    }

    if (showNewFolder) NameDialog("New Folder", "") { name -> scope.launch { ctrl.mkdir(name) }; showNewFolder = false }
    renameTarget?.let { e -> NameDialog("Rename", e.name) { name -> scope.launch { ctrl.rename(e, name) }; renameTarget = null } }
    deleteTarget?.let { e ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete “${e.name}”?") },
            text = { Text(if (e.isDir) "This folder and everything in it will be permanently deleted." else "This file will be permanently deleted.", color = fDim) },
            confirmButton = { TextButton(onClick = { scope.launch { ctrl.delete(e) }; deleteTarget = null }) { Text("Delete", color = fBad) } },
            dismissButton = { TextButton(onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun FileViewer(file: OpenFile, onBack: () -> Unit, onSave: (String) -> Unit, onDownload: () -> Unit) {
    var editing by remember { mutableStateOf(false) }
    var draft by remember(file.path) { mutableStateOf(file.text ?: "") }
    var fontSize by remember { mutableStateOf(13f) }
    var scale by remember { mutableStateOf(1f) }
    val dirty = file.kind == Kind.TEXT && draft != (file.text ?: "")

    Column(Modifier.fillMaxSize().background(fInk)) {
        Row(Modifier.fillMaxWidth().background(fPanel).padding(horizontal = 6.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.Filled.ArrowBack, "Back", tint = fDim) }
            Text(file.name, color = fText, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (file.kind == Kind.TEXT || file.kind == Kind.IMAGE) {
                IconButton(onClick = { if (file.kind == Kind.TEXT) fontSize = (fontSize - 1).coerceAtLeast(7f) else scale = (scale / 1.25f).coerceAtLeast(0.25f) }) {
                    Icon(Icons.Filled.Remove, "Smaller", tint = fDim)
                }
                IconButton(onClick = { if (file.kind == Kind.TEXT) fontSize = (fontSize + 1).coerceAtMost(40f) else scale = (scale * 1.25f).coerceAtMost(8f) }) {
                    Icon(Icons.Filled.Add, "Larger", tint = fDim)
                }
            }
            IconButton(onClick = onDownload) { Icon(Icons.Filled.Download, "Download", tint = fDim) }
            if (file.kind == Kind.TEXT) {
                if (editing) {
                    IconButton(onClick = { onSave(draft); editing = false }, enabled = dirty) {
                        Icon(Icons.Filled.Done, "Save", tint = if (dirty) fAccent else fFaint)
                    }
                } else {
                    IconButton(onClick = { editing = true }) { Icon(Icons.Filled.Edit, "Edit", tint = fDim) }
                }
            }
        }
        when (file.kind) {
            Kind.TEXT -> {
                if (editing) {
                    BasicTextField(
                        value = draft, onValueChange = { draft = it },
                        textStyle = TextStyle(color = fText, fontFamily = FontFamily.Monospace, fontSize = fontSize.sp),
                        cursorBrush = androidx.compose.ui.graphics.SolidColor(fAccent),
                        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp),
                    )
                } else {
                    Text(file.text ?: "", color = fText.copy(alpha = 0.92f), fontFamily = FontFamily.Monospace, fontSize = fontSize.sp,
                        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp))
                }
            }
            Kind.IMAGE -> {
                val bmp = file.image
                if (bmp != null) {
                    Box(
                        Modifier.fillMaxSize().pointerInput(Unit) {
                            detectTransformGestures { _, _, zoom, _ -> scale = (scale * zoom).coerceIn(0.25f, 8f) }
                        },
                        contentAlignment = Alignment.Center,
                    ) {
                        androidx.compose.foundation.Image(
                            bitmap = bmp.asImageBitmap(), contentDescription = file.name,
                            modifier = Modifier.fillMaxWidth().padding(8.dp).graphicsLayer(scaleX = scale, scaleY = scale),
                        )
                    }
                } else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Couldn't decode image", color = fDim) }
            }
            Kind.PDF -> {
                val pages = file.pages.orEmpty()
                if (pages.isEmpty()) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Couldn't render PDF", color = fDim) }
                else LazyColumn(Modifier.fillMaxSize().background(fPanelAlt)) {
                    items(pages) { bmp ->
                        androidx.compose.foundation.Image(
                            bitmap = bmp.asImageBitmap(), contentDescription = null,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
                        )
                    }
                }
            }
            Kind.BINARY -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("${file.name}\nnot a previewable file — use Download", color = fDim, modifier = Modifier.padding(24.dp))
            }
        }
    }
}

@Composable
private fun TransferBanner(verb: String, name: String, prog: Float) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
        Text("$verb $name… ${(prog * 100).toInt()}%", color = fDim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Box(Modifier.fillMaxWidth().padding(top = 5.dp).height(3.dp).background(fBorder, RoundedCornerShape(2.dp))) {
            Box(Modifier.fillMaxWidth(prog.coerceIn(0f, 1f)).height(3.dp).background(fAccent, RoundedCornerShape(2.dp)))
        }
    }
}

@Composable
private fun NameDialog(title: String, initial: String, onConfirm: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = { onConfirm("") },
        title = { Text(title) },
        text = { OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, placeholder = { Text("name") }) },
        confirmButton = { TextButton(onClick = { if (name.isNotBlank()) onConfirm(name.trim()) }) { Text("OK") } },
        dismissButton = { TextButton(onClick = { onConfirm("") }) { Text("Cancel") } },
    )
}

private fun renderPdf(ctx: Context, bytes: ByteArray): List<Bitmap> = try {
    val tmp = File.createTempFile("ut-pdf", ".pdf", ctx.cacheDir).apply { writeBytes(bytes) }
    val pfd = ParcelFileDescriptor.open(tmp, ParcelFileDescriptor.MODE_READ_ONLY)
    val renderer = PdfRenderer(pfd)
    val out = ArrayList<Bitmap>()
    val count = minOf(renderer.pageCount, 80)   // cap to keep memory sane
    for (i in 0 until count) {
        val page = renderer.openPage(i)
        val targetW = 1080
        val scale = (targetW.toFloat() / page.width).coerceIn(1f, 3f)
        val w = (page.width * scale).toInt()
        val h = (page.height * scale).toInt()
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(android.graphics.Color.WHITE)
        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
        page.close()
        out.add(bmp)
    }
    renderer.close(); pfd.close(); tmp.delete()
    out
} catch (_: Exception) { emptyList() }

private fun displayName(ctx: Context, uri: Uri): String {
    var name = "upload"
    runCatching {
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0) name = c.getString(i)
            }
        }
    }
    return name
}

private fun byteSize(n: Long): String {
    if (n < 1024) return "$n B"
    val units = listOf("KB", "MB", "GB", "TB"); var v = n / 1024.0; var i = 0
    while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
    return if (v >= 100) "%.0f %s".format(v, units[i]) else "%.1f %s".format(v, units[i])
}
