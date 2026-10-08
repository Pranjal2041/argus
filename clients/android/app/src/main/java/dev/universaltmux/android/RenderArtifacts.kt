package dev.universaltmux.android

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.pdf.PdfDocument
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.PixelCopy
import android.webkit.WebView
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal fun pdfPageCuts(height: Float, pageHeight: Float, protectedSpans: List<Pair<Float, Float>>): List<Float> {
    require(height > 0 && pageHeight > 0)
    val cuts = mutableListOf(0f)
    while (cuts.last() < height) {
        val start = cuts.last()
        var end = minOf(height, start + pageHeight)
        while (true) {
            val boundary = protectedSpans.filter { (top, bottom) -> top < end && bottom > end && top > start + 1 && bottom - top <= pageHeight }
                .minOfOrNull { it.first } ?: break
            if (boundary >= end) break
            end = boundary
        }
        check(end > start) { "PDF pagination could not advance" }
        cuts.add(end)
        check(cuts.size <= 1001) { "The rendered document exceeds 1,000 PDF pages" }
    }
    return cuts
}

private suspend fun renderGeometry(view: WebView): JSONObject = suspendCancellableCoroutine { continuation ->
    // Our bundled renderer owns this document.
    view.evaluateJavascript("""(() => {
      const spans = [], add = r => { if(r.width > 0 && r.height > 0) spans.push([r.top + scrollY, r.bottom + scrollY]); };
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while(node = walker.nextNode()) {
        if(!node.textContent.trim() || /^(SCRIPT|STYLE)$/.test(node.parentElement.tagName)) continue;
        const range = document.createRange(); range.selectNodeContents(node);
        Array.from(range.getClientRects()).forEach(add);
      }
      document.querySelectorAll('img,svg,canvas,tr,p').forEach(e => add(e.getBoundingClientRect()));
      document.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(e => {
        const next = e.nextElementSibling;
        if(next) spans.push([e.getBoundingClientRect().top + scrollY, next.getBoundingClientRect().bottom + scrollY]);
      });
      return {width: window.visualViewport ? window.visualViewport.width : document.documentElement.clientWidth,
        height: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight), spans};
    })()""".trimIndent()) { value ->
        if (continuation.isActive) try { continuation.resume(JSONObject(value)) }
        catch (error: Exception) { continuation.resumeWithException(error) }
    }
}

private suspend fun awaitRenderFrame(view: WebView) = suspendCancellableCoroutine<Unit> { continuation ->
    view.postVisualStateCallback(System.nanoTime(), object : WebView.VisualStateCallback() {
        override fun onComplete(requestId: Long) {
            // Visual-state completion promises the NEXT draw contains the update.
            // Resume after that frame's traversal, not before its pixels commit.
            Choreographer.getInstance().postFrameCallback {
                view.post { Choreographer.getInstance().postFrameCallback {
                    view.post { if (continuation.isActive) continuation.resume(Unit) }
                } }
            }
        }
    })
    view.invalidate()
}

private fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> if (baseContext !== this) baseContext.activity() else null
    else -> null
}

private suspend fun copyViewport(view: WebView): Bitmap = suspendCancellableCoroutine { continuation ->
    val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
    val location = IntArray(2); view.getLocationInWindow(location)
    val window = view.context.activity()?.window
    if (window == null) {
        bitmap.recycle()
        continuation.resumeWithException(IllegalStateException("The document window is unavailable"))
    } else PixelCopy.request(window, Rect(location[0], location[1], location[0] + view.width, location[1] + view.height),
        bitmap, { result ->
            if (result == PixelCopy.SUCCESS && continuation.isActive) continuation.resume(bitmap)
            else {
                bitmap.recycle()
                if (continuation.isActive) continuation.resumeWithException(IllegalStateException("The document frame could not be captured ($result)"))
            }
        }, Handler(Looper.getMainLooper()))
}

private suspend fun scrollDocument(view: WebView, y: Float): Unit = suspendCancellableCoroutine { continuation ->
    view.evaluateJavascript("window.scrollTo(0, $y)") { if (continuation.isActive) continuation.resume(Unit) }
}

private suspend fun documentScroll(view: WebView): Float = suspendCancellableCoroutine { continuation ->
    view.evaluateJavascript("window.scrollY") { value ->
        if (continuation.isActive) continuation.resume(value.toFloatOrNull() ?: 0f)
    }
}

/** Capture the actual composited viewport. Software WebView.draw display lists
 * are neither a full document nor a reliable viewport under hardware rendering. */
suspend fun renderPDF(view: WebView, file: File) {
    check(view.width > 0 && view.height > 0) { "The rendered document is not ready" }
    val bounds = renderGeometry(view)
    val margin = 28f; val width = 595; val height = 842
    val scale = (width - margin * 2) / view.width
    val coordinateScale = view.width / bounds.getDouble("width").toFloat()
    val spans = bounds.getJSONArray("spans").let { rows -> (0 until rows.length()).map { index ->
        val span = rows.getJSONArray(index)
        (span.getDouble(0).toFloat() * coordinateScale) to (span.getDouble(1).toFloat() * coordinateScale)
    } }
    val cuts = pdfPageCuts(bounds.getDouble("height").toFloat() * coordinateScale, (height - margin * 2) / scale, spans)
    val pdf = PdfDocument()
    val originalX = view.scrollX; val originalY = view.scrollY
    try {
        for (index in 0 until cuts.size - 1) {
            val page = pdf.startPage(PdfDocument.PageInfo.Builder(width, height, index + 1).create())
            page.canvas.drawColor(android.graphics.Color.WHITE)
            var tileStart = cuts[index]
            while (tileStart < cuts[index + 1]) {
                scrollDocument(view, kotlin.math.floor(tileStart / coordinateScale))
                awaitRenderFrame(view)
                val scrollY = documentScroll(view) * coordinateScale
                val bitmap = copyViewport(view)
                try {
                    val tileEnd = minOf(cuts[index + 1], scrollY + view.height.toFloat())
                    check(tileEnd > tileStart) { "The document changed during export. Try saving again." }
                    page.canvas.save()
                    page.canvas.clipRect(margin, margin + (tileStart - cuts[index]) * scale,
                        width - margin, margin + (tileEnd - cuts[index]) * scale)
                    page.canvas.translate(margin, margin + (scrollY - cuts[index]) * scale)
                    page.canvas.scale(scale, scale)
                    page.canvas.drawBitmap(bitmap, 0f, 0f, null)
                    page.canvas.restore()
                    tileStart = tileEnd
                } finally { bitmap.recycle() }
            }
            pdf.finishPage(page)
        }
        file.outputStream().use { pdf.writeTo(it); it.fd.sync() }
    } finally { view.scrollTo(originalX, originalY); pdf.close() }
}

/** Authored source and the captured plain terminal text both survive export.
 * Styling is explicitly plain because this capture does not claim styled cells. */
internal fun renderSourceArchive(document: RenderContent, fontSize: Int): JSONObject {
    val style = JSONObject().put("foreground", "#1f2328").put("background", "#fbfbfa")
        .put("bold", false).put("italic", false).put("strikethrough", false)
    val terminal = JSONObject().put("columns", document.terminalText.lines().maxOfOrNull { it.length } ?: 80)
        .put("fontFamily", "monospace").put("foreground", "#1f2328").put("background", "#fbfbfa")
        .put("styles", JSONArray().put(style)).put("lines", JSONArray(document.terminalText.lines().map { line ->
            JSONObject().put("wrapped", false).put("runs", JSONArray().put(JSONObject().put("text", line).put("style", 0)))
        }))
    return JSONObject().put("schemaVersion", 1).put("presentation", "rendered").put("fontSize", fontSize)
        .put("document", JSONObject().put("id", UUID.randomUUID().toString()).put("source", document.text)
            .put("sourceOrigin", document.sourceOrigin).put("terminal", terminal))
}
