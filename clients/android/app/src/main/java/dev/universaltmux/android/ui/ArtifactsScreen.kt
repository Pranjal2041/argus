package dev.universaltmux.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

const val SCREEN_ARTIFACTS = 16

@Composable
fun ArtifactsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var query by rememberSaveable { mutableStateOf("") }
    var selectedID by rememberSaveable(vm.workspace.workspaceID) { mutableStateOf<String?>(null) }
    LaunchedEffect(vm.requestedArtifactID) { vm.requestedArtifactID?.let { selectedID = it; vm.requestedArtifactID = null } }
    var rename by remember { mutableStateOf<WorkspaceRecord?>(null) }
    var name by remember { mutableStateOf("") }
    var deleting by remember { mutableStateOf<WorkspaceRecord?>(null) }
    var issue by remember { mutableStateOf<String?>(null) }
    val rows = vm.workspace.collection("artifacts").sortedByDescending { it.data?.optJSONObject("record")?.optString("createdAt").orEmpty() }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                var filename = "artifact"
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor -> if (cursor.moveToFirst()) filename = cursor.getString(0) }
                val input = context.contentResolver.openInputStream(uri) ?: error("The selected file could not be opened")
                vm.artifactTransfers.stage(input, filename, context.contentResolver.getType(uri), vm.artifactPanel(), vm.selected?.first?.brokerID)
                vm.refreshArtifactTransfers()
            } catch (e: Exception) { issue = e.message }
        }
    }
    val selected = rows.firstOrNull { it.id == selectedID }
    if (selected != null) {
        SharedArtifactPreview(vm, selected) { selectedID = null }
    } else LazyColumn(Modifier.fillMaxSize().padding(horizontal = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp), contentPadding = PaddingValues(vertical = 16.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Artifacts", fontSize = 26.sp, color = LocalTheme.current.text, modifier = Modifier.weight(1f))
                Button(onClick = { picker.launch(arrayOf("*/*")) }, enabled = vm.workspace.workspaceID.isNotEmpty()) { Text("Save file") }
            }
            Text("Saved files, renders, and screenshots across your devices", fontSize = 12.sp, color = LocalTheme.current.dim)
            (issue ?: vm.artifactTransfers.issue ?: vm.workspace.issue)?.let { Text(it, color = LocalTheme.current.waiting) }
        }
        vm.artifactTransfers.activeJobs().forEach { job -> item(key = "transfer-${job.optString("id")}") {
            Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(12.dp)) {
                Text(job.optJSONObject("record")?.optString("filename").orEmpty())
                Text(if (vm.artifactTransfers.uploading) "Uploading…" else "Saved on this phone · upload pending", fontSize = 12.sp)
                TextButton(onClick = { scope.launch { vm.artifactTransfers.flush(vm.workspaceHost(), true); vm.refreshWorkspace(true) } }, enabled = !vm.artifactTransfers.uploading) { Text("Retry") }
            } }
        } }
        item { OutlinedTextField(query, { query = it }, label = { Text("Search files, panels, or hosts") }, modifier = Modifier.fillMaxWidth()) }
        items(rows.filter { it.data?.toString()?.contains(query, true) == true }, key = { it.id }) { row ->
            val record = row.data?.optJSONObject("record") ?: JSONObject()
            val panel = record.optJSONObject("panel") ?: JSONObject()
            Card(Modifier.fillMaxWidth().clickable { selectedID = row.id }) {
                Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    Text(record.optString("filename"), fontSize = 17.sp)
                    Text("${panel.optString("machineName")} · ${panel.optString("sessionName")}", fontSize = 12.sp)
                    val created = runCatching { java.time.Instant.parse(record.optString("createdAt")).toEpochMilli() }.getOrDefault(0)
                    Text("${workspaceDate(created)} · ${record.optLong("byteCount") / 1024} KiB", fontSize = 11.sp)
                    Row { TextButton(onClick = { selectedID = row.id }) { Text("Open") }; TextButton(onClick = { rename = row; name = record.optString("filename") }) { Text("Rename") }; TextButton(onClick = { deleting = row }) { Text("Delete") } }
                }
            }
        }
        if (rows.isEmpty()) item { Text("No shared artifacts yet", color = LocalTheme.current.dim) }
    }
    rename?.let { row -> AlertDialog(onDismissRequest = { rename = null }, title = { Text("Rename artifact") }, text = { OutlinedTextField(name, { name = it }, label = { Text("Filename") }) },
        confirmButton = { TextButton(enabled = name.isNotBlank(), onClick = {
            val data = JSONObject(row.data.toString()); data.getJSONObject("record").put("filename", name.trim().substringAfterLast('/').substringAfterLast('\\')).put("titleSource", "manual")
            vm.changeShared("artifacts", row.id, data); rename = null
        }) { Text("Save") } }, dismissButton = { TextButton(onClick = { rename = null }) { Text("Cancel") } }) }
    deleting?.let { row -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Delete this artifact from the workspace?") },
        confirmButton = { TextButton(onClick = { vm.changeShared("artifacts", row.id, null, true); deleting = null }) { Text("Delete") } }, dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } }) }
}

@Composable
private fun SharedArtifactPreview(vm: AppViewModel, row: WorkspaceRecord, close: () -> Unit) {
    val record = row.data?.optJSONObject("record") ?: JSONObject()
    val hash = row.data?.optString("hash").orEmpty()
    var file by remember(hash) { mutableStateOf<File?>(null) }
    var issue by remember(hash) { mutableStateOf<String?>(null) }
    var sourceText by remember(hash) { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val coroutine = rememberCoroutineScope()
    val download = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(record.optString("contentType", "application/octet-stream"))) { uri ->
        val source = file
        if (uri != null && source != null) coroutine.launch {
            try { withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri)?.use { output -> source.inputStream().use { it.copyTo(output) } } ?: error("Could not open download destination") } }
            catch (e: Exception) { issue = e.message }
        }
    }
    LaunchedEffect(hash, vm.workspaceHost()?.id) {
        try { file = withContext(Dispatchers.IO) { vm.workspaceBlobs.download(vm.workspaceHost(), hash) } }
        catch (e: Exception) { issue = e.message }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = close) { Text("Library") }
            Text(record.optString("filename"), fontSize = 14.sp, color = LocalTheme.current.text, modifier = Modifier.weight(1f))
            TextButton(onClick = { download.launch(record.optString("filename", "artifact")) }, enabled = file != null) { Text("Download") }
        }
        row.data?.optString("sourceHash")?.takeIf { it.isNotEmpty() }?.let { sourceHash ->
            TextButton(onClick = { coroutine.launch {
                try {
                    sourceText = withContext(Dispatchers.IO) {
                        val archive = JSONObject(vm.workspaceBlobs.download(vm.workspaceHost(), sourceHash).readText())
                        archive.getJSONObject("document").getString("source")
                    }
                } catch (e: Exception) { issue = e.message }
            } }) { Text("View authored source") }
        }
        issue?.let { Text(it, color = LocalTheme.current.waiting, modifier = Modifier.padding(14.dp)) }
        if (file == null && issue == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        file?.let { NativeDocumentPreview(it, record.optString("filename"), record.optString("contentType"), Modifier.weight(1f)) }
    }
    sourceText?.let { TextDocumentDialog("Authored source", it) { sourceText = null } }
}

private class PDFDocument(file: File) : AutoCloseable {
    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = PdfRenderer(descriptor)
    val count = renderer.pageCount
    @Synchronized fun render(index: Int): Bitmap = renderer.openPage(index).use { page ->
        val scale = minOf(1440f / page.width, 4096f / page.height)
        val bitmap = Bitmap.createBitmap((page.width * scale).toInt().coerceAtLeast(1), (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.WHITE); page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY); bitmap
    }
    @Synchronized override fun close() { renderer.close(); descriptor.close() }
}

@Composable
internal fun NativeDocumentPreview(file: File, filename: String, contentType: String, modifier: Modifier = Modifier) {
    var image by remember(file) { mutableStateOf<Bitmap?>(null) }
    var text by remember(file) { mutableStateOf<String?>(null) }
    var error by remember(file) { mutableStateOf<String?>(null) }
    var pdf by remember(file) { mutableStateOf<PDFDocument?>(null) }
    var page by rememberSaveable(file.path) { mutableStateOf(0) }
    DisposableEffect(file) { onDispose { pdf?.close(); pdf = null } }
    LaunchedEffect(file) {
        try {
            withContext(Dispatchers.IO) {
                when {
                    filename.endsWith(".pdf", true) || contentType == "application/pdf" -> pdf = PDFDocument(file)
                    contentType.startsWith("image/") || filename.substringAfterLast('.').lowercase() in listOf("png", "jpg", "jpeg", "gif", "webp", "bmp") -> {
                        val bounds = BitmapFactory.Options().also { it.inJustDecodeBounds = true }; BitmapFactory.decodeFile(file.path, bounds)
                        val options = BitmapFactory.Options().also { it.inSampleSize = maxOf(1, maxOf(bounds.outWidth, bounds.outHeight) / 2048) }
                        image = BitmapFactory.decodeFile(file.path, options) ?: error("Image could not be decoded")
                    }
                    file.length() <= 4 * 1024 * 1024 -> {
                        val bytes = file.readBytes()
                        if (bytes.any { it == 0.toByte() }) error = "Download this file to open it in a compatible viewer."
                        else text = bytes.toString(Charsets.UTF_8)
                    }
                    else -> error = "Download this file to open it in a compatible viewer."
                }
            }
        } catch (e: Exception) { error = e.message }
    }
    LaunchedEffect(pdf, page) { pdf?.let { document -> try { image = withContext(Dispatchers.IO) { document.render(page.coerceIn(0, document.count - 1)) } } catch (e: Exception) { error = e.message } } }
    Column(modifier.fillMaxWidth()) {
        pdf?.let { document -> Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center) {
            TextButton(onClick = { page-- }, enabled = page > 0) { Text("Previous") }
            Text("${page + 1} / ${document.count}", color = LocalTheme.current.text, modifier = Modifier.padding(horizontal = 12.dp))
            TextButton(onClick = { page++ }, enabled = page + 1 < document.count) { Text("Next") }
        } }
        error?.let { Text(it, color = LocalTheme.current.dim, modifier = Modifier.padding(18.dp)) }
        image?.let { Image(it.asImageBitmap(), filename, modifier = Modifier.fillMaxWidth().weight(1f)) }
        text?.let { SelectionContainer { Text(it, color = LocalTheme.current.text, fontFamily = FontFamily.Monospace, fontSize = 13.sp, modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp)) } }
    }
}
