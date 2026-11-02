package org.mai.kotlin

import android.content.Context
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.ViewConfiguration
import android.widget.FrameLayout
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.viewinterop.AndroidView
import org.connectbot.terminal.Terminal
import org.connectbot.terminal.VTermKey
import kotlin.math.abs
import kotlin.math.max

@Composable internal fun TerminalViewport(
    session: TerminalSessions.ShellSession, fontSize: TextUnit, modifier: Modifier, swipeKeys: Boolean,
    onZoom: (Float) -> Unit, onZoomFinished: () -> Unit,
) {
    val composition = rememberCompositionContext()
    val zoom by rememberUpdatedState(onZoom)
    val finished by rememberUpdatedState(onZoomFinished)
    val content by rememberUpdatedState<@Composable () -> Unit> {
        // The emulator belongs to the session, so font/viewport changes resize
        // its grid and the PTY without replacing the shell or its history.
        Terminal(session.emulator, initialFontSize = fontSize,
            minFontSize = fontSize, maxFontSize = fontSize,
            keyboardEnabled = session.canInput, modifierManager = session.modifiers)
    }
    AndroidView(modifier = modifier.clipToBounds(), factory = { context ->
        TerminalTouchLayout(context, { zoom(it) }, { finished() }, { key ->
            session.emulator.dispatchKey(session.modifiers.mask(), key)
            session.modifiers.clearTransients()
        }).apply {
            addView(ComposeView(context).apply {
                setParentCompositionContext(composition)
                setContent { content() }
            }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        }
    }, update = { it.swipeKeys = swipeKeys })
}

// termlib 0.0.x ignores Compose pointer consumption during its image-style
// zoom/pan gesture. Intercept multitouch at the View boundary: Android sends
// CANCEL to that gesture while single-finger scrolling/selection still works.
private class TerminalTouchLayout(context: Context, onZoom: (Float) -> Unit, onFinished: () -> Unit,
    private val onKey: (Int) -> Unit) : FrameLayout(context) {
    var swipeKeys = false
    private var pinching = false
    private var swiping = false
    private var horizontal = false
    private var originX = 0f
    private var originY = 0f
    private var remainder = 0f
    private var sent = false
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val step = max(slop * 2f, 24f * resources.displayMetrics.density)
    private val scale = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            onZoom(detector.scaleFactor)
            return true
        }
        override fun onScaleEnd(detector: ScaleGestureDetector) = onFinished()
    }).apply { isQuickScaleEnabled = false }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            pinching = false; swiping = false; sent = false; remainder = 0f
            originX = event.x; originY = event.y
        }
        if (event.pointerCount > 1) {
            pinching = true
        }
        if (pinching || swipeKeys && event.actionMasked == MotionEvent.ACTION_MOVE) {
            // Compose may have claimed the first finger for scrolling already.
            super.requestDisallowInterceptTouchEvent(false)
        }
        scale.onTouchEvent(event)
        val handled = super.dispatchTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) pinching = false
        return handled
    }
    override fun onInterceptTouchEvent(event: MotionEvent): Boolean {
        if (pinching || swiping) return true
        // Leave taps and long-press text selection to termlib. Pinch always
        // takes priority, including when a second finger joins a swipe.
        if (swipeKeys && event.actionMasked == MotionEvent.ACTION_MOVE &&
            event.eventTime - event.downTime < ViewConfiguration.getLongPressTimeout()) {
            val dx = event.x - originX
            val dy = event.y - originY
            if (max(abs(dx), abs(dy)) > slop) {
                horizontal = abs(dx) > abs(dy)
                swiping = true
                parent.requestDisallowInterceptTouchEvent(true)
                return true
            }
        }
        return false
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!pinching && swiping && event.actionMasked != MotionEvent.ACTION_CANCEL) {
            val delta = if (horizontal) event.x - originX else event.y - originY
            originX = event.x; originY = event.y
            remainder += delta
            val key = if (horizontal) {
                if (remainder < 0) VTermKey.RIGHT else VTermKey.LEFT
            } else {
                if (remainder < 0) VTermKey.DOWN else VTermKey.UP
            }
            val count = (abs(remainder) / step).toInt()
            repeat(count) { onKey(key); sent = true }
            remainder %= step
            if (event.actionMasked == MotionEvent.ACTION_UP && !sent && remainder != 0f) onKey(key)
        }
        return true
    }
}
