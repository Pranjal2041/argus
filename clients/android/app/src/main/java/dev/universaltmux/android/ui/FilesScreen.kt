package dev.universaltmux.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import org.json.JSONArray
import org.json.JSONObject

private val fInk: Color @Composable get() = LocalTheme.current.bgDeep
private val fPanel: Color @Composable get() = LocalTheme.current.panel
private val fAccent: Color @Composable get() = LocalTheme.current.accent
private val fDim: Color @Composable get() = LocalTheme.current.dim
private val fFaint: Color @Composable get() = LocalTheme.current.faint
private val fText: Color @Composable get() = LocalTheme.current.text
private val fBorder: Color @Composable get() = LocalTheme.current.border
private val fBad: Color @Composable get() = LocalTheme.current.bad
private val fPanelAlt: Color @Composable get() = LocalTheme.current.panelAlt

enum class Kind { TEXT, IMAGE, PDF, BINARY }
class OpenFile(
    val path: String, val name: String, val kind: Kind,
    val text: String? = null, val image: Bitmap? = null, val previewFile: File? = null,
    val revision: String = "", val draftText: String? = null,
)

/** Per-host browsing state (single-directory navigation, mobile-style). */
class FilesController(var broker: Broker, val ctx: Context) {
    var path by mutableStateOf("")
    var sep = "/"
    var entries by mutableStateOf<List<FileEntry>>(emptyList())
    var loading by mutableStateOf(false)
    var open by mutableStateOf<OpenFile?>(null)
    var uploading by mutableStateOf<Pair<String, Float>?>(null)   // (name, 0..1)
    var downloading by mutableStateOf<Pair<String, Float>?>(null)
    var error by mutableStateOf<String?>(null)
    var saving by mutableStateOf(false)
    var conflict by mutableStateOf<FileDocument?>(null)
    var tabs by mutableStateOf<List<String>>(emptyList()); private set
    var contentResults by mutableStateOf<List<JSONObject>>(emptyList()); private set
    var searchingContents by mutableStateOf(false); private set
    var searchTruncated by mutableStateOf(false); private set
    var gitMarks by mutableStateOf<Map<String, String>>(emptyMap()); private set
    private var listing = 0L
    private var searching = 0L
    private val drafts = EditorDraftStore(File(ctx.filesDir, "editor-drafts"))
    private val prefs = ctx.getSharedPreferences("ut.files", Context.MODE_PRIVATE)
    private val identity get() = broker.brokerID.ifEmpty { broker.id }
    private var started = false
    private var opening = 0L

    private fun readDraft(path: String): EditorDraft? = try {
        drafts.read(identity, path) ?: if (identity != broker.id) drafts.read(broker.id, path) else null
    } catch (_: Exception) { error = "A saved draft could not be read. Its file has been retained."; null }

    fun rememberDraft(file: OpenFile, text: String) {
        try { drafts.save(identity, file.path, EditorDraft(file.revision, file.text ?: "", text)) }
        catch (_: Exception) { error = "Could not persist the latest draft. Keep this editor open." }
    }

    fun closeFile() { open = null; opening++; prefs.edit().remove("open.${broker.id}").apply() }
    fun closeTab(path: String) {
        tabs = tabs - path
        prefs.edit().putString("tabs.${broker.id}", JSONArray(tabs).toString()).apply()
        if (open?.path == path) closeFile()
    }

    suspend fun start() {
        if (started) return
        started = true
        tabs = runCatching { JSONArray(prefs.getString("tabs.${broker.id}", "[]")).strings() }.getOrDefault(emptyList())
        val h = withContext(Dispatchers.IO) { Net.fsHome(broker) }
        if (h != null) { sep = h.sep; go(prefs.getString("path.${broker.id}", h.home) ?: h.home) } else go(prefs.getString("path.${broker.id}", "") ?: "")
        prefs.getString("open.${broker.id}", null)?.let { path ->
            openEntry(FileEntry(path.substringAfterLast(sep), path, false, 0, 0, ""))
        }
    }
    suspend fun go(p: String) {
        val request = ++listing
        loading = true
        val list = withContext(Dispatchers.IO) { Net.fsList(broker, p) }
        if (request != listing) return
        loading = false
        if (list != null) {
            if (path != p) { contentResults = emptyList(); searchTruncated = false; searching++; searchingContents = false; gitMarks = emptyMap() }
            path = p
            prefs.edit().putString("path.${broker.id}", p).apply()
            entries = list.sortedWith(compareByDescending<FileEntry> { it.isDir }.thenBy { it.name.lowercase() })
            error = null
            val summary = withContext(Dispatchers.IO) { runCatching { JSONObject(BrokerDocuments.read(broker, "/git/summary", mapOf("dir" to p))) }.getOrNull() }
            if (request != listing) return
            val root = summary?.optString("root").orEmpty().replace('\\', '/').trimEnd('/')
            gitMarks = summary?.optJSONArray("files").objects().associate { row ->
                val mark = if (row.optBoolean("untracked")) "?" else (row.optString("staged") + row.optString("unstaged")).filter { it != '.' && it != ' ' }.ifEmpty { "M" }
                (root + "/" + row.optString("path").replace('\\', '/')) to mark
            }
        } else error = "Could not refresh this folder. The previous listing is retained."
    }
    suspend fun searchContents(query: String) {
        val request = ++searching; val root = path
        searchingContents = true
        try {
            val result = withContext(Dispatchers.IO) { JSONObject(BrokerDocuments.read(broker, "/fs/grep", mapOf("path" to root, "query" to query))) }
            if (request == searching && root == path) { contentResults = result.optJSONArray("matches").objects(); searchTruncated = result.optBoolean("truncated"); error = null }
        } catch (failure: Exception) { if (request == searching) error = failure.message }
        finally { if (request == searching) searchingContents = false }
    }
    fun gitMark(entry: FileEntry): String? {
        val path = entry.path.replace('\\', '/')
        return gitMarks[path] ?: if (entry.isDir && gitMarks.keys.any { it.startsWith(path.trimEnd('/') + "/") }) "M" else null
    }
    suspend fun up() = go(parent(path))

    suspend fun openEntry(e: FileEntry) {
        if (e.isDir) { go(e.path); return }
        val request = ++opening
        error = null; conflict = null
        var resolved: OpenFile
        var remoteConflict: FileDocument? = null
        var loadIssue: String? = null
        when (kindOf(e.name)) {
            Kind.IMAGE -> {
                val bytes = withContext(Dispatchers.IO) { Net.fsReadBytes(broker, e.path) }
                val bmp = bytes?.let { runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull() }
                resolved = OpenFile(e.path, e.name, if (bmp != null) Kind.IMAGE else Kind.BINARY, image = bmp)
            }
            Kind.PDF -> {
                val file = try { withContext(Dispatchers.IO) {
                    val target = File(ctx.cacheDir, "remote-previews/" + BrokerDocuments.digest(identity + "\u0000" + e.path) + ".pdf")
                    target.parentFile?.mkdirs()
                    val temp = File.createTempFile("download-", ".tmp", target.parentFile)
                    try {
                        val downloaded = temp.outputStream().use { output ->
                            val ok = Net.fsDownloadTo(broker, e.path, output) { received, total -> check(received <= 128L * 1024 * 1024 && total <= 128L * 1024 * 1024) { "PDF exceeds 128 MiB" } }
                            output.fd.sync(); ok
                        }
                        if (downloaded) check(temp.renameTo(target)) { "PDF could not be cached" }
                        else if (!target.isFile) error("PDF download failed")
                        else loadIssue = "Host unavailable; showing the cached PDF."
                        target
                    } finally { temp.delete() }
                } } catch (failure: Exception) { loadIssue = failure.message; null }
                resolved = OpenFile(e.path, e.name, if (file != null) Kind.PDF else Kind.BINARY, previewFile = file)
            }
            Kind.TEXT -> {
                if (e.size > 5_000_000) { if (request == opening) open = OpenFile(e.path, e.name, Kind.BINARY); return }
                val draft = readDraft(e.path)
                val document = withContext(Dispatchers.IO) { Net.fsDocument(broker, e.path) }
                val text = document?.text ?: if (draft == null) withContext(Dispatchers.IO) { Net.fsReadBytes(broker, e.path)?.toString(Charsets.UTF_8) } else null
                resolved = when {
                    draft != null -> OpenFile(e.path, e.name, Kind.TEXT, text = draft.base, revision = draft.revision, draftText = draft.text)
                    text != null -> OpenFile(e.path, e.name, Kind.TEXT, text = text, revision = document?.revision.orEmpty())
                    else -> OpenFile(e.path, e.name, Kind.BINARY)
                }
                if (draft != null && document != null && draft.revision != document.revision) {
                    remoteConflict = document
                }
            }
            Kind.BINARY -> resolved = OpenFile(e.path, e.name, Kind.BINARY)
        }
        if (request != opening) return
        open = resolved; conflict = remoteConflict
        if (loadIssue != null) error = loadIssue
        if (remoteConflict != null) error = "The remote file changed. Your recovered draft is retained."
        if (e.path !in tabs) tabs = tabs + e.path
        prefs.edit().putString("open.${broker.id}", e.path).putString("tabs.${broker.id}", JSONArray(tabs).toString()).apply()
    }

    suspend fun save(file: OpenFile, text: String): Boolean {
        if (saving) return false
        saving = true; rememberDraft(file, text)
        try {
            val result = withContext(Dispatchers.IO) { Net.fsSaveDocument(broker, file.path, file.revision, text) }
            error = result.error; conflict = result.conflict
            val document = result.document ?: return false
            withContext(Dispatchers.IO) { drafts.remove(identity, file.path); if (identity != broker.id) drafts.remove(broker.id, file.path) }
            if (open?.path == file.path) open = OpenFile(file.path, file.name, Kind.TEXT, text = document.text, revision = document.revision)
            return true
        } catch (e: Exception) { error = e.message ?: "Save failed; draft retained."; return false }
        finally { saving = false }
    }

    fun rebaseDraft(file: OpenFile, text: String) {
        val remote = conflict ?: return
        val rebased = OpenFile(file.path, file.name, Kind.TEXT, text = remote.text, revision = remote.revision, draftText = text)
        rememberDraft(rebased, text); open = rebased; conflict = null; error = null
    }
    suspend fun mkdir(name: String) { if (name.isBlank()) return; if (withContext(Dispatchers.IO) { Net.fsMkdir(broker, joined(path, name)) }) go(path) }
    suspend fun rename(e: FileEntry, name: String) {
        if (name.isBlank()) return
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
    val ctrl = vm.filesFor(broker)
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
        Column(Modifier.fillMaxSize()) {
        FileTabs(ctrl) { path -> scope.launch { ctrl.openEntry(FileEntry(path.substringAfterLast(ctrl.sep), path, false, 0, 0, "")) } }
        Box(Modifier.weight(1f)) { FileViewer(open, saving = ctrl.saving, error = ctrl.error, conflict = ctrl.conflict,
            onDraft = { ctrl.rememberDraft(open, it) }, onRebase = { ctrl.rebaseDraft(open, it) }, onBack = { ctrl.closeFile() },
            onSave = { text, complete -> vm.saveFile(ctrl, open, text, complete) },
            onDownload = { download(open.path, open.name) }) }
        }
        return
    }

    var menuOpen by remember { mutableStateOf(false) }
    var showNewFolder by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<FileEntry?>(null) }
    var deleteTarget by remember { mutableStateOf<FileEntry?>(null) }
    var searching by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var contentSearch by remember { mutableStateOf(false) }
    LaunchedEffect(ctrl.path) { search = "" }   // filter is depth-1: reset it when the folder changes

    Column(Modifier.fillMaxSize().background(fInk)) {
        FileTabs(ctrl) { path -> scope.launch { ctrl.openEntry(FileEntry(path.substringAfterLast(ctrl.sep), path, false, 0, 0, "")) } }
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
                placeholder = { Text(if (contentSearch) "Search file contents recursively" else "Filter this folder") },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            )
            Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                FilterChip(selected = contentSearch, onClick = { contentSearch = !contentSearch }, label = { Text("File contents") })
                if (contentSearch) TextButton(onClick = { scope.launch { ctrl.searchContents(search) } }, enabled = search.isNotBlank() && !ctrl.searchingContents) { Text("Search contents") }
            }
        }
        ctrl.error?.let { Text(it, color = fBad, modifier = Modifier.padding(12.dp), fontSize = 12.sp) }
        ctrl.uploading?.let { (n, p) -> TransferBanner("Uploading", n, p) }
        ctrl.downloading?.let { (n, p) -> TransferBanner("Downloading", n, p) }

        val shown = if (search.isBlank()) ctrl.entries else ctrl.entries.filter { it.name.contains(search, ignoreCase = true) }
        if (searching && contentSearch) {
            if (ctrl.searchingContents) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (ctrl.searchTruncated) Text("Showing the first matches; narrow your search for more.", color = fDim, modifier = Modifier.padding(12.dp), fontSize = 12.sp)
            LazyColumn(Modifier.fillMaxSize()) {
                items(ctrl.contentResults) { match ->
                    val target = match.getString("path")
                    Column(Modifier.fillMaxWidth().clickable { scope.launch { ctrl.openEntry(FileEntry(target.substringAfterLast(ctrl.sep), target, false, 0, 0, "")) } }.padding(12.dp)) {
                        Text(target + ":" + match.optInt("line"), color = fAccent, fontSize = 12.sp)
                        Text(match.optString("text"), color = fText, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        } else if (ctrl.loading && ctrl.entries.isEmpty()) {
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
                        ctrl.gitMark(e)?.let { Text(it, color = fAccent, fontSize = 11.sp, fontFamily = FontFamily.Monospace, modifier = Modifier.padding(horizontal = 8.dp)) }
                        if (!e.isDir) Text(byteSize(e.size), color = fFaint, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                        Box {
                            IconButton(onClick = { rowMenu = true }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Filled.MoreVert, "More", tint = fFaint, modifier = Modifier.size(18.dp))
                            }
                            DropdownMenu(rowMenu, onDismissRequest = { rowMenu = false }) {
                                DropdownMenuItem(text = { Text("Open") }, onClick = { rowMenu = false; scope.launch { ctrl.openEntry(e) } })
                                if (!e.isDir) DropdownMenuItem(text = { Text("Download") }, onClick = { rowMenu = false; download(e.path, e.name) })
                                if (!e.isDir) DropdownMenuItem(text = { Text("Save to artifacts") }, onClick = { rowMenu = false; vm.snapshotArtifact(broker, e.path, e.name) })
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
private fun FileTabs(controller: FilesController, select: (String) -> Unit) {
    if (controller.tabs.isEmpty()) return
    Row(Modifier.fillMaxWidth().background(fPanel).horizontalScroll(rememberScrollState()).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        controller.tabs.forEach { path ->
            InputChip(selected = controller.open?.path == path, onClick = { select(path) }, enabled = !controller.saving,
                label = { Text(path.substringAfterLast(controller.sep), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 150.dp)) },
                trailingIcon = { IconButton(onClick = { controller.closeTab(path) }, enabled = !controller.saving, modifier = Modifier.size(24.dp)) { Icon(Icons.Default.Close, "Close tab", modifier = Modifier.size(14.dp)) } },
                modifier = Modifier.padding(end = 6.dp))
        }
    }
}

@Composable
private fun FileViewer(file: OpenFile, saving: Boolean, error: String?, conflict: FileDocument?,
                       onDraft: (String) -> Unit, onRebase: (String) -> Unit, onBack: () -> Unit,
                       onSave: (String, (Boolean) -> Unit) -> Unit, onDownload: () -> Unit) {
    var editing by remember(file.path, file.revision) { mutableStateOf(file.draftText != null) }
    var draft by remember(file.path, file.revision) { mutableStateOf(file.draftText ?: file.text ?: "") }
    var confirmRebase by remember { mutableStateOf(false) }
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
                    IconButton(onClick = { onSave(draft) { success -> if (success) editing = false } }, enabled = dirty && !saving) {
                        Icon(Icons.Filled.Done, "Save", tint = if (dirty) fAccent else fFaint)
                    }
                } else {
                    IconButton(onClick = { editing = true }) { Icon(Icons.Filled.Edit, "Edit", tint = fDim) }
                }
            }
        }
        if (saving) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (error != null) {
            Text(error, color = fBad, fontSize = 12.sp, modifier = Modifier.padding(12.dp))
            if (conflict != null) TextButton(onClick = { confirmRebase = true }) { Text("Review remote change") }
        }
        when (file.kind) {
            Kind.TEXT -> {
                if (editing) {
                    BasicTextField(
                        value = draft, onValueChange = { draft = it; onDraft(it) }, enabled = !saving,
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
                file.previewFile?.let { NativeDocumentPreview(it, file.name, "application/pdf", Modifier.fillMaxSize()) }
            }
            Kind.BINARY -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("${file.name}\nnot a previewable file — use Download", color = fDim, modifier = Modifier.padding(24.dp))
            }
        }
    }
    if (confirmRebase && conflict != null) AlertDialog(
        onDismissRequest = { confirmRebase = false }, title = { Text("Remote file changed") },
        text = { Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
            Text("Remote version", fontSize = 12.sp); Text(conflict.text, fontFamily = FontFamily.Monospace, fontSize = 11.sp)
        } },
        confirmButton = { TextButton(onClick = { onRebase(draft); confirmRebase = false }) { Text("Keep my draft for next save") } },
        dismissButton = { TextButton(onClick = { confirmRebase = false }) { Text("Cancel") } },
    )
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
