package me.albemala.native_video_player

/**
 * Immuch360 (patch 5): when the position the player reads at each tick goes to Flutter. Each one rebuilds the
 * controls and asks for a frame, so the interval while the video plays is the redraw rate of the window: 100 ms on a
 * phone, where the frames, the Dart isolate and the media bridge share the main thread, and the 8 ms tick on a Meta
 * Quest, whose window must present at least 60 frames a second while a video plays (VRC.Quest.Performance.1). The app
 * gives the interval (PlayerSetup.positionIntervalMs). A position that did not change is never sent; a jump back or
 * of more than [JUMP_MS] (a seek), and any change while the video does not play, go at once.
 */
class PositionPacer(intervalMs: Long) {
    companion object {
        /** The interval while the video plays when the app gives none */
        const val DEFAULT_INTERVAL_MS = 100L

        /** How often the player reads its position */
        const val TICK_MS = 8L

        /** A move by more than this while the video plays is a seek */
        const val JUMP_MS = 1000L
    }

    val intervalMs: Long = intervalMs.coerceAtLeast(0L)

    private var lastPosition = -1L
    private var lastSentAt = 0L

    /** Whether [position], read at [now] (ms of a monotonic clock) while the video [playing] or not, goes to Flutter */
    fun shouldSend(position: Long, playing: Boolean, now: Long): Boolean {
        if (position == lastPosition) return false
        val jumped = lastPosition < 0 || position < lastPosition || position - lastPosition > JUMP_MS
        if (playing && !jumped && now - lastSentAt < intervalMs) return false
        lastPosition = position
        lastSentAt = now
        return true
    }
}
