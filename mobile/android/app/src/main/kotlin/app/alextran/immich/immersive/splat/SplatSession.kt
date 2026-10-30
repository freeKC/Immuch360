package app.alextran.immich.immersive.splat

/**
 * The life of the splat entity of the viewer (lot S5), and the calls on it each state allows, so that the viewer
 * never touches an entity the Spatial SDK let go, nor shows two splats at once ("Only one splat can be rendered at a
 * time", https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-splats/).
 *
 * IDLE, then PREPARING while the file is read, weighed and reduced off the main thread; LOADING once the entity is
 * made, until the module says the file loaded (SplatLoadEventArgs, success or not); SHOWN or FAILED then. Another media
 * or the end of the viewer drops it: a shown or failed splat is destroyed at once, one still loading only once its
 * load ends (the module may still be reading the file for it), or after [LOAD_TIMEOUT_MS]. A splat asked
 * for while another is being dropped waits for it ([whenFree]).
 *
 * At the shutdown of the scene (onSpatialShutdown, before onDestroy) the SDK takes the entities with it: [shutDown]
 * forgets every handle and from then on nothing reaches [Effects], whatever comes later (a load event, a drop of
 * onDestroy, a timeout). Pure JVM, tested by SplatSessionTest with a fake of the entity.
 */
internal class SplatSession<H : Any>(private val effects: Effects<H>) {
  /** What the viewer does with the entity of the SDK, on the main thread */
  interface Effects<H> {
    fun destroy(handle: H)

    fun show(handle: H)
  }

  enum class State {
    IDLE,
    PREPARING,
    LOADING,
    SHOWN,
    FAILED,
    DOWN,
  }

  /** What a load event did */
  enum class Loaded {
    /** The splat of the viewer loaded and shows */
    SHOWN,

    /** It did not load: its entity is gone, the viewer says why */
    FAILED,

    /** A splat dropped while it loaded: gone now */
    DROPPED,

    /** An event of no splat the session knows, or after the shutdown: nothing done */
    IGNORED,
  }

  var state = State.IDLE
    private set

  /** The entity of the splat of the viewer, null without one */
  var handle: H? = null
    private set

  /** An entity dropped while it loaded, destroyed at its load event */
  private var dropping: H? = null
  private var waiting: (() -> Unit)? = null

  val isDown: Boolean
    get() = state == State.DOWN

  /** A new splat is being read: false once the scene is down (nothing may be made then) */
  fun prepare(): Boolean {
    if (state == State.DOWN) return false
    drop()
    state = State.PREPARING
    return true
  }

  /**
   * Runs [start] (which makes the entity) now when no dropped splat is still loading, else once it is gone; never
   * once the scene is down
   */
  fun whenFree(start: () -> Unit) {
    if (state == State.DOWN) return
    if (dropping == null) start() else waiting = start
  }

  /** The entity [made] for the splat being prepared: false when it must not be kept (no splat prepared, or down) */
  fun made(made: H): Boolean {
    if (state != State.PREPARING) return false
    handle = made
    state = State.LOADING
    return true
  }

  /** The module said that [loaded] finished loading, [success] or not */
  fun loaded(loaded: H, success: Boolean): Loaded {
    if (state == State.DOWN) return Loaded.IGNORED
    if (loaded === dropping) {
      release()
      return Loaded.DROPPED
    }
    if (loaded !== handle || state != State.LOADING) return Loaded.IGNORED
    return if (success) {
      state = State.SHOWN
      effects.show(loaded)
      Loaded.SHOWN
    } else {
      state = State.FAILED
      handle = null
      effects.destroy(loaded)
      Loaded.FAILED
    }
  }

  /** No load event came for [late] in [LOAD_TIMEOUT_MS]: taken as a failure, or the dropped one let go */
  fun timedOut(late: H): Loaded = loaded(late, success = false)

  /** Another media, or the end of the viewer before the scene goes: the splat goes, now or once it loaded */
  fun drop() {
    if (state == State.DOWN) return
    val current = handle
    handle = null
    waiting = null
    when (state) {
      State.LOADING ->
        if (current != null) {
          // A splat dropped before is still loading: this one goes at once, the module being busy with the other
          if (dropping == null) dropping = current else effects.destroy(current)
        }
      State.SHOWN -> current?.let(effects::destroy)
      else -> Unit
    }
    state = State.IDLE
  }

  /** The scene of the SDK goes down with its entities: no call on them from now on */
  fun shutDown() {
    state = State.DOWN
    handle = null
    dropping = null
    waiting = null
  }

  private fun release() {
    val gone = dropping ?: return
    dropping = null
    effects.destroy(gone)
    waiting?.let {
      waiting = null
      it()
    }
  }

  companion object {
    /** How long a load may take before the viewer gives up on it */
    const val LOAD_TIMEOUT_MS = 60_000L
  }
}
