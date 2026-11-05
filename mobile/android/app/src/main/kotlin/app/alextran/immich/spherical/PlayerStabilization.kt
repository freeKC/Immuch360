package app.alextran.immich.spherical

/**
 * What Flutter tells the 360° player about the stabilisation of a video (issue 14), see
 * [SphericalVideoApi.setStabilization]: called right before the player opens, while Flutter reads the motion track,
 * then once more with the table. The player is an activity of its own that may not exist yet, or may be recreated: the
 * last message waits here for the URL it is about, and the player that plays that URL listens. Main thread only.
 */
internal object StabilizationInbox {
  /** [table] is null while Flutter reads the track ([hasTrack] true) and for a file without one */
  data class Message(
    val url: String,
    val enabled: Boolean,
    val hasTrack: Boolean,
    val table: StabilizationTable?,
    val summary: String?,
  )

  private var latest: Message? = null
  private var listener: ((Message) -> Unit)? = null

  /** Keeps [message] for the player of its URL, and hands it to the player that listens */
  fun post(message: Message) {
    latest = message
    listener?.invoke(message)
  }

  /** The last message about [url], null when there is none */
  fun latestFor(url: String?): Message? = latest?.takeIf { it.url == url }

  /** [listener] gets every message from now on, in place of the one before; null stops it */
  fun listen(listener: ((Message) -> Unit)?) {
    this.listener = listener
  }

  /**
   * Stops [listener], unless another one took its place: a player that closes may go after the next one opened
   */
  fun stopListening(listener: (Message) -> Unit) {
    if (this.listener === listener) this.listener = null
  }

  /** Forgets the message about [url]: its player closed */
  fun forget(url: String?) {
    if (latest?.url == url) latest = null
  }
}

/**
 * The stabilisation switch of the 360° player and what follows from it: whether its button shows, which table the
 * frames get, whether Media3 may apply a CAMM track of the file, and which notice to show. Pure Kotlin, so that the
 * rules are tested without a device; the activity applies what it says.
 *
 * The button shows for a file with a motion track: a raw video whose track Flutter reads or has read, or a video with
 * a CAMM track, which Media3 applies itself. Off, the frames get no rotation and the CAMM track is disabled in the
 * track selection: off means the raw video for every file. On with a table, the table turns the frames and the CAMM
 * track, if any, stays disabled, so that the view gets one rotation.
 */
internal class StabilizationSwitch(enabled: Boolean) {
  /** What the player knows of the motion track of the file */
  enum class Track { UNKNOWN, PENDING, READY, NONE }

  /** A notice to show for a few seconds */
  enum class Notice { STABILIZED, NO_TRACK }

  /** The switch: on by default, as the setting */
  var enabled: Boolean = enabled
    private set

  var track: Track = Track.UNKNOWN
    private set

  /** The table of the file, once Flutter sent it */
  var table: StabilizationTable? = null
    private set

  /** The file has a CAMM track (camera motion), which Media3 would apply */
  var hasCamm: Boolean = false

  // The user pressed the button in this player: the setting Flutter sends no longer moves the switch
  private var touched = false

  // The user turned the switch on in this player: a file without a track then says so
  private var turnedOnByUser = false

  // "Stabilised..." showed once already in this player
  private var stabilizedNoticeShown = false

  /** Whether the button shows */
  val buttonVisible: Boolean
    get() = track == Track.PENDING || track == Track.READY || hasCamm

  /** Whether the CAMM track of the file must be disabled in the track selection */
  val cammDisabled: Boolean
    get() = !enabled || table != null

  /**
   * The table the frames of a player get: none when off, and none when the frame shown is not the stitched sphere
   * ([stitched] false: an unstitched raw frame, whose picture the table does not describe)
   */
  fun activeTable(stitched: Boolean): StabilizationTable? = if (enabled && stitched) table else null

  /**
   * What Flutter said about the file (see [StabilizationInbox]): the table, or that it reads the track ([hasTrack]
   * without a table), or that the file has none. A table refused by the player counts as none. A file without a track
   * says so only when the user turned the switch on in this player.
   */
  fun onTrack(hasTrack: Boolean, table: StabilizationTable?): Notice? {
    this.table = if (hasTrack) table else null
    track = when {
      !hasTrack -> Track.NONE
      table != null -> Track.READY
      else -> Track.PENDING
    }
    return if (track == Track.NONE && enabled && turnedOnByUser && !hasCamm) Notice.NO_TRACK else null
  }

  /** The setting Flutter sent, unless the user already pressed the button in this player */
  fun onSetting(enabled: Boolean) {
    if (!touched) this.enabled = enabled
  }

  /** Restores the switch of a recreated player, as [touched], [userTurnedOn] and [stabilizedNoticeWasShown] said */
  fun restore(enabled: Boolean, touched: Boolean, turnedOnByUser: Boolean, stabilizedNoticeShown: Boolean) {
    this.enabled = enabled
    this.touched = touched
    this.turnedOnByUser = turnedOnByUser
    this.stabilizedNoticeShown = stabilizedNoticeShown
  }

  /** The user pressed the button in this player */
  val wasTouched: Boolean
    get() = touched

  val userTurnedOn: Boolean
    get() = turnedOnByUser

  val stabilizedNoticeWasShown: Boolean
    get() = stabilizedNoticeShown

  /**
   * The user pressed the button: the switch flips. Turned on, the notice tells what the user gets: stabilised when the
   * file has a table or a CAMM track, no track when it turned out to have none; nothing while the track is read (the
   * notice comes with the first stabilised frame).
   */
  fun toggle(): Notice? {
    touched = true
    enabled = !enabled
    if (!enabled) return null
    turnedOnByUser = true
    return when {
      table != null || hasCamm -> {
        stabilizedNoticeShown = true
        Notice.STABILIZED
      }
      track == Track.NONE -> Notice.NO_TRACK
      else -> null
    }
  }

  /** A frame was drawn with the table: the first one of this player tells the user, once */
  fun onStabilizedFrame(): Notice? {
    if (stabilizedNoticeShown) return null
    stabilizedNoticeShown = true
    return Notice.STABILIZED
  }
}
