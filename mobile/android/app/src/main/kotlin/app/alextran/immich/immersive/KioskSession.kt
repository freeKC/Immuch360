package app.alextran.immich.immersive

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The texts of a kiosk opening, as Flutter sends them (the kiosk JSON of ImmersiveApi.open, in the language of the
 * app): [endText] on the card at the end of the film, [exitHint] passing at the start to say how to leave.
 */
internal data class KioskOptions(val endText: String, val exitHint: String) {
  companion object {
    private val json = Json { ignoreUnknownKeys = true }

    /** The options of [text], or null for an opening that is no kiosk: no JSON, or a JSON that is not an object. */
    fun parse(text: String?): KioskOptions? {
      if (text.isNullOrBlank()) return null
      val root =
        try {
          json.parseToJsonElement(text) as? JsonObject
        } catch (e: Exception) {
          null
        } ?: return null
      return KioskOptions(endText = root.text("endText"), exitHint = root.text("exitHint"))
    }

    private fun JsonObject.text(key: String): String =
      (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.content.orEmpty()
  }
}

/**
 * The kiosk mode of the immersive viewer of the Meta Quest (lot quest-kiosk, 29 October 2026): one 360° film or photo
 * the app opened at its start for the visitors of an exhibition, the need shown by the exhibition builds of
 * ppawelstachh-sys/Immuch360 (branch immuch360), rewritten here. The viewer reports what happens, this class says what
 * to do; it calls nothing itself, so that every rule is unit tested.
 *
 * - At the start, the viewer says once how to leave ([Command.SHOW_EXIT_NOTICE]).
 * - The headset taken off pauses a film and lets its player go ([Command.RELEASE_PLAYER]); put on again by the next
 *   visitor, the film starts again from 0:00 on a new player ([Command.RESTART]). A photo stays as it is. A headset
 *   put on without a removal first (the first mount, the system repeating it) changes nothing.
 * - The film plays once (no loop): its end shows the end card on a dark sphere where the visitor looks
 *   ([Command.SHOW_END_CARD]), until the headset is taken off and put on again.
 * - A playback failure in the last [END_MARGIN_MS] of a film of at least [MIN_FILM_MS] counts as its end: the decoder
 *   crash that the exhibition met at a fixed point near the end of its film. An earlier failure is left to the viewer,
 *   which tries the server's transcoded stream first; the error left after that shows on the card
 *   ([Command.SHOW_ERROR_CARD]) and the next visitor gets a new try from the start.
 * - Only B or Y held [EXIT_HOLD_MS] leaves ([Command.EXIT]), counted once both were seen released, so that a button
 *   held when the kiosk starts never closes it.
 */
internal class KioskSession(private val isVideo: Boolean) {
  enum class State {
    /** The media is on: a film plays, or waits for the system to give the focus back. */
    WATCHING,

    /** Nobody wears the headset: a film is paused and its player gone. */
    UNWORN,

    /** The film ended: the end card on the dark sphere. */
    ENDED,

    /** The media failed: the error card on the dark sphere. */
    FAILED,

    /** Left with B or Y: nothing else happens. */
    EXITED,
  }

  enum class Command {
    SHOW_EXIT_NOTICE,
    RELEASE_PLAYER,
    RESTART,
    SHOW_END_CARD,
    SHOW_ERROR_CARD,
    EXIT,
  }

  var state = State.WATCHING
    private set

  private var started = false

  /** The headset came off since the end card or the error card showed: the next mount restarts. */
  private var removedSinceCard = false

  /** B or Y were seen released since the start: a hold counts from then on. */
  private var exitArmed = false

  /** When the hold of B or Y began (uptime ms), null while neither is held. */
  private var exitHeldSince: Long? = null

  /** The kiosk opened: say how to leave, once. */
  fun start(): List<Command> {
    if (started) return emptyList()
    started = true
    return listOf(Command.SHOW_EXIT_NOTICE)
  }

  /** The headset was taken off (onHMDUnmounted). */
  fun onUnmounted(): List<Command> =
    when (state) {
      State.WATCHING -> {
        state = State.UNWORN
        if (isVideo) listOf(Command.RELEASE_PLAYER) else emptyList()
      }
      State.ENDED,
      State.FAILED -> {
        removedSinceCard = true
        emptyList()
      }
      State.UNWORN,
      State.EXITED -> emptyList()
    }

  /** The headset was put on (onHMDMounted). */
  fun onMounted(): List<Command> =
    when (state) {
      State.UNWORN -> {
        state = State.WATCHING
        if (isVideo) listOf(Command.RESTART) else emptyList()
      }
      State.ENDED,
      State.FAILED ->
        if (removedSinceCard) {
          state = State.WATCHING
          removedSinceCard = false
          listOf(Command.RESTART)
        } else {
          emptyList()
        }
      State.WATCHING,
      State.EXITED -> emptyList()
    }

  /** The film reached its end (STATE_ENDED: no loop in a kiosk). */
  fun onEnded(): List<Command> {
    if (!isVideo || state != State.WATCHING) return emptyList()
    state = State.ENDED
    removedSinceCard = false
    return listOf(Command.RELEASE_PLAYER, Command.SHOW_END_CARD)
  }

  /**
   * The player failed at [positionMs] of a film of [durationMs] (negative or 0 when unknown). Within its last seconds
   * (see [isPracticallyFinished]) the film counts as ended; otherwise nothing, and the viewer goes on with its own
   * fallbacks, then [onError] for what is left.
   */
  fun onPlaybackFailure(positionMs: Long, durationMs: Long): List<Command> {
    if (!isVideo || state != State.WATCHING || !isPracticallyFinished(positionMs, durationMs)) return emptyList()
    return onEnded()
  }

  /** An error the viewer could not get around (no fallback left, a photo that does not load). */
  fun onError(): List<Command> {
    val wasUnworn =
      when (state) {
        State.WATCHING -> false
        State.UNWORN -> true
        State.ENDED,
        State.FAILED,
        State.EXITED -> return emptyList()
      }
    state = State.FAILED
    removedSinceCard = wasUnworn
    // While unworn, the player of a film is gone already
    return if (isVideo && !wasUnworn) listOf(Command.RELEASE_PLAYER, Command.SHOW_ERROR_CARD)
    else listOf(Command.SHOW_ERROR_CARD)
  }

  /** Every frame: whether B or Y is [held] now, at [nowMs] (uptime). */
  fun onExitButtons(held: Boolean, nowMs: Long): List<Command> {
    if (state == State.EXITED) return emptyList()
    if (!held) {
      exitArmed = true
      exitHeldSince = null
      return emptyList()
    }
    if (!exitArmed) return emptyList()
    val since = exitHeldSince ?: nowMs.also { exitHeldSince = it }
    if (nowMs - since < EXIT_HOLD_MS) return emptyList()
    state = State.EXITED
    return listOf(Command.EXIT)
  }

  companion object {
    /** How long B or Y is held to leave the kiosk. */
    const val EXIT_HOLD_MS = 1_000L

    /** A failure this close to the end of a film counts as its end. */
    const val END_MARGIN_MS = 15_000L

    /** A film shorter than this never takes a failure for its end. */
    const val MIN_FILM_MS = 30_000L

    /** Whether a failure at [positionMs] of a film of [durationMs] comes within its last [END_MARGIN_MS]. */
    fun isPracticallyFinished(positionMs: Long, durationMs: Long): Boolean =
      durationMs >= MIN_FILM_MS && positionMs >= durationMs - END_MARGIN_MS
  }
}
