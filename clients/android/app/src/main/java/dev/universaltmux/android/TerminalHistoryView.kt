package dev.universaltmux.android

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.doOnLayout
import com.termux.terminal.TextStyle
import com.termux.view.TerminalView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Full-screen applications without mouse reporting do not offer terminal
 * scrollback. A swipe opens an independent, immutable output document instead
 * of impersonating Up/Down keys. The live terminal and its IME stay attached.
 * The loader is transport/provider-neutral and cancellable. No network response
 * can replace the live screen or a later history request.
 */
class TerminalHistoryView(
    context: Context,
    val terminal: TerminalView,
    private val load: ((TerminalHistoryText?) -> Unit) -> (() -> Unit),
) : FrameLayout(context) {
    private val overlay = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private val title = TextView(context)
    internal val liveButton = TextView(context)
    internal val historyText = TextView(context)
    internal val historyScroll = ScrollView(context)
    var isHistoryVisible = false
        private set
    var onHistoryVisibilityChanged: ((Boolean) -> Unit)? = null

    private var requestGeneration = 0
    private var cancelRequest: (() -> Unit)? = null
    private var disposed = false
    private var contentReady = false
    private var pendingPixels = 0f
    private var pendingVelocity = 0
    private var draggingFromTerminal = false
    private var downX = 0f
    private var downY = 0f
    private var lastY = 0f
    private var velocity: VelocityTracker? = null
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val maximumVelocity = ViewConfiguration.get(context).scaledMaximumFlingVelocity
    private val minimumVelocity = ViewConfiguration.get(context).scaledMinimumFlingVelocity
    private val density = resources.displayMetrics.density

    init {
        addView(terminal, LayoutParams(-1, -1))
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(6), 0)
            setBackgroundColor(Color.rgb(35, 37, 49))
        }
        title.setTextColor(Color.rgb(212, 215, 229))
        title.textSize = 13f
        header.addView(title, LinearLayout.LayoutParams(0, -2, 1f))
        liveButton.apply {
            text = "Live ↓"
            contentDescription = "Return to live terminal"
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(Color.rgb(184, 199, 255))
            setPadding(dp(16), 0, dp(16), 0)
            setOnClickListener { returnToLive() }
        }
        header.addView(liveButton, LinearLayout.LayoutParams(-2, dp(44)))
        overlay.addView(header)
        historyText.apply {
            typeface = Typeface.MONOSPACE
            setPadding(dp(10), dp(10), dp(10), dp(16))
            // Keep focus/IME on the live terminal. This surface is not an editor.
            isFocusable = false
        }
        historyScroll.apply {
            isFillViewport = true
            descendantFocusability = FOCUS_BLOCK_DESCENDANTS
            overScrollMode = OVER_SCROLL_IF_CONTENT_SCROLLS
            addView(historyText, FrameLayout.LayoutParams(-1, -2))
        }
        overlay.addView(historyScroll, LinearLayout.LayoutParams(-1, 0, 1f))
        // INVISIBLE, not GONE: the first drag already has real viewport geometry.
        overlay.visibility = View.INVISIBLE
        addView(overlay, LayoutParams(-1, -1))
        terminal.setOnUserInput { returnToLive() }
    }

    private fun dp(value: Int) = (density * value).roundToInt()

    private fun usesReadOnlyHistory(): Boolean = terminal.mEmulator?.let {
        it.isAlternateBufferActive && !it.isMouseTrackingActive
    } == true

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        if (isHistoryVisible) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                lastY = event.y
                velocity?.recycle()
                velocity = VelocityTracker.obtain().also { it.addMovement(event) }
            }
            MotionEvent.ACTION_MOVE -> {
                val distance = downY - event.y
                if (usesReadOnlyHistory() && distance < -touchSlop && abs(distance) > abs(event.x - downX)) {
                    draggingFromTerminal = true
                    lastY = event.y
                    velocity?.addMovement(event)
                    showHistory(distance)
                    parent?.requestDisallowInterceptTouchEvent(true)
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> recycleVelocity()
        }
        return false
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!draggingFromTerminal) return super.onTouchEvent(event)
        velocity?.addMovement(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_MOVE -> {
                val pixels = lastY - event.y
                lastY = event.y
                if (contentReady) historyScroll.scrollBy(0, pixels.roundToInt())
                else pendingPixels += pixels
            }
            MotionEvent.ACTION_UP -> {
                velocity?.computeCurrentVelocity(1000, maximumVelocity.toFloat())
                val speed = -(velocity?.yVelocity ?: 0f).roundToInt()
                if (abs(speed) >= minimumVelocity) {
                    if (contentReady) historyScroll.fling(speed) else pendingVelocity = speed
                }
                draggingFromTerminal = false
                recycleVelocity()
            }
            MotionEvent.ACTION_CANCEL -> {
                draggingFromTerminal = false
                pendingVelocity = 0
                recycleVelocity()
            }
        }
        return true
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (!isHistoryVisible && usesReadOnlyHistory() && event.actionMasked == MotionEvent.ACTION_SCROLL) {
            val ticks = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
            if (ticks > 0) {
                showHistory(-ticks * terminal.mRenderer.fontLineSpacing * 3)
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    fun showHistory(initialPixels: Float = 0f) {
        if (disposed || isHistoryVisible) return
        val generation = ++requestGeneration
        val emulator = terminal.mEmulator ?: return
        val fallback = emulator.screen.transcriptText
        isHistoryVisible = true
        contentReady = false
        pendingPixels = initialPixels
        pendingVelocity = 0
        title.text = "Loading output history…"
        historyText.text = ""
        overlay.setBackgroundColor(emulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND])
        historyText.setTextColor(emulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_FOREGROUND])
        historyText.setTextSize(TypedValue.COMPLEX_UNIT_PX, terminal.mRenderer.textSize.toFloat())
        overlay.visibility = View.VISIBLE
        onHistoryVisibilityChanged?.invoke(true)
        cancelRequest = load { result ->
            post resultReady@{
                if (disposed || !isHistoryVisible || generation != requestGeneration) return@resultReady
                title.text = if (result?.origin == "conversation") "Conversation history" else "Output history"
                historyText.text = result?.text?.takeIf { it.isNotBlank() } ?: fallback
                // Freeze this document until Live. Streaming terminal redraws
                // and late fetches cannot move the user's reading position.
                historyText.doOnLayout layoutReady@{
                    if (disposed || !isHistoryVisible || generation != requestGeneration) return@layoutReady
                    val bottom = (historyText.height - historyScroll.height).coerceAtLeast(0)
                    historyScroll.scrollTo(0, (bottom + pendingPixels).roundToInt().coerceAtLeast(0))
                    contentReady = true
                    if (!draggingFromTerminal && pendingVelocity != 0) historyScroll.fling(pendingVelocity)
                    pendingVelocity = 0
                }
            }
        }
    }

    fun returnToLive() {
        if (!isHistoryVisible) return
        requestGeneration++
        cancelRequest?.invoke()
        cancelRequest = null
        isHistoryVisible = false
        draggingFromTerminal = false
        recycleVelocity()
        overlay.visibility = View.INVISIBLE
        onHistoryVisibilityChanged?.invoke(false)
    }

    fun dispose() {
        returnToLive()
        disposed = true
        terminal.setOnUserInput(null)
    }

    private fun recycleVelocity() {
        velocity?.recycle()
        velocity = null
    }
}
