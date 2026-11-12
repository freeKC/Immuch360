package app.alextran.immich.immersive

import app.alextran.immich.spherical.StabilizationInbox
import app.alextran.immich.spherical.StabilizationSwitch
import app.alextran.immich.spherical.StabilizationTable
import app.alextran.immich.spherical.StabilizedFrames
import app.alextran.immich.spherical.StabilizedStitch

/**
 * What Flutter tells the immersive viewer about the stabilisation of a raw 360° video (issue 14, lot d3), see
 * ImmersiveApi.setStabilization: called right before the viewer opens or shows a video (the setting, and whether
 * Flutter reads a motion track), then once more with the table. The viewer is an activity of its own that may not
 * exist yet: the last message about each URL waits here, and the viewer that shows that URL listens, the way
 * [StabilizationInbox] serves the phone's player (a separate inbox, so that neither player takes the other's
 * listener). The last [MAX_URLS] URLs are kept: the media shown, and the previous or next one Flutter may send
 * meanwhile. Main thread only.
 */
internal object ImmersiveStabilizationInbox {
  const val MAX_URLS = 3

  private val latest = LinkedHashMap<String, StabilizationInbox.Message>()
  private var listener: ((StabilizationInbox.Message) -> Unit)? = null

  /** Keeps [message] for the viewer of its URL, and hands it to the viewer that listens */
  fun post(message: StabilizationInbox.Message) {
    latest.remove(message.url)
    latest[message.url] = message
    while (latest.size > MAX_URLS) latest.remove(latest.keys.first())
    listener?.invoke(message)
  }

  /** The last message about [url], null when there is none */
  fun latestFor(url: String?): StabilizationInbox.Message? = url?.let { latest[it] }

  /** [listener] gets every message from now on, in place of the one before */
  fun listen(listener: (StabilizationInbox.Message) -> Unit) {
    this.listener = listener
  }

  /** Stops [listener], unless another one took its place: a viewer that closes may go after the next one opened */
  fun stopListening(listener: (StabilizationInbox.Message) -> Unit) {
    if (this.listener === listener) this.listener = null
  }

  /** Forgets every message: the tests start from nothing */
  fun clear() {
    latest.clear()
    listener = null
  }
}

/**
 * The stabilisation of the immersive viewer of the Meta Quest (issue 14, lot d3): the switch of the raw video shown
 * ([StabilizationSwitch], as the phone's player has it), the table its frames get, turned inside the stitch
 * ([stitch], handed to the side by side effect and to the lens compositor), and the time base of the frames the
 * stitch gets ([onPlay]). Off, or for a frame that is not the stitched sphere, the stitch gets the identity: the raw
 * video as before.
 *
 * One per viewer. Each media gets a fresh switch ([onMedia]) that starts where the user left the one before in this
 * viewer once pressed, else at the setting Flutter sends; previous and next keep it. Pure Kotlin, the activity applies
 * what it says: [onChanged] after every change of the button (visible, on or off), [onNotice] for a notice to show,
 * [onToggled] when the user pressed the button (the setting of the app follows), all on the main thread, where
 * [postToMain] brings the first stabilised frame of the stitch's GL thread.
 */
internal class ImmersiveStabilization(
  postToMain: (() -> Unit) -> Unit,
  private val onChanged: () -> Unit,
  private val onNotice: (StabilizationSwitch.Notice) -> Unit,
  private val onToggled: (Boolean) -> Unit,
) {
  /** What the stitch of the viewer's players reads for each frame */
  val stitch = StabilizedStitch { postToMain(::onFirstStabilizedFrame) }

  // The switch of the media shown; null for none (a photo, a video that is not raw)
  private var switch: StabilizationSwitch? = null

  // The URL Flutter keys the messages of the media shown on (the URL it opened, not a fallback or a lens file)
  private var url: String? = null

  // The user pressed the button in this viewer, which then wins over the setting for the next media: where it is
  private var pressed: Boolean? = null

  // Whether the frame shown is the stitched sphere, whose picture the table describes
  private var stitched = false

  /** The inbox listener of this viewer, see [listen] */
  val listener: (StabilizationInbox.Message) -> Unit = { onMessage(it) }

  /** Whether the button shows: a raw video whose track Flutter reads or has read, while its frame is stitched */
  val buttonVisible: Boolean
    get() = switch?.buttonVisible == true

  /** Whether the switch is on */
  val enabled: Boolean
    get() = switch?.enabled == true

  /**
   * The viewer shows the media at [mediaUrl], a raw 360° video when [rawVideo] (any other media gets no switch): its
   * switch starts at the setting of the last message about it, if any, or where the user left it in this viewer
   */
  fun onMedia(mediaUrl: String?, rawVideo: Boolean) {
    url = if (rawVideo) mediaUrl else null
    // Until its player says how it stitches (onPlay)
    stitched = false
    val message = ImmersiveStabilizationInbox.latestFor(url)
    switch =
      if (url == null) {
        null
      } else {
        StabilizationSwitch(pressed ?: message?.enabled ?: true).also { fresh ->
          // Pressed in this viewer: the setting a message brings no longer moves it
          pressed?.let { fresh.restore(it, touched = true, turnedOnByUser = false, stabilizedNoticeShown = false) }
          fresh.stitched = false
        }
      }
    if (message != null) apply(message) else update()
  }

  /**
   * The player of the media starts at [startPositionMs] with [plan]'s stitch: [sideBySide] for the effect of a side by
   * side frame (its frames come [StabilizedFrames.timeBaseUs] early), [stitchedFrame] false for a raw frame shown
   * unstitched (a fallback), where the table would turn nothing it describes
   */
  fun onPlay(sideBySide: Boolean, stitchedFrame: Boolean, startPositionMs: Long) {
    stitch.timeBaseUs = StabilizedFrames.timeBaseUs(sideBySide, startPositionMs)
    stitched = stitchedFrame
    switch?.stitched = stitchedFrame
    update()
  }

  /** The user pressed the button: the switch flips, the setting of the app follows */
  fun toggle() {
    val current = switch ?: return
    val notice = current.toggle()
    pressed = current.enabled
    update()
    onToggled(current.enabled)
    notice?.let(onNotice)
  }

  /** The viewer closes: no table any more, nothing more told */
  fun release() {
    switch = null
    url = null
    stitch.table = null
    ImmersiveStabilizationInbox.stopListening(listener)
  }

  /** The viewer listens to the inbox from now on */
  fun listen() = ImmersiveStabilizationInbox.listen(listener)

  private fun onMessage(message: StabilizationInbox.Message) {
    // A message about another media (one Flutter is about to show, one shown before) waits in the inbox
    if (message.url != url) return
    apply(message)
  }

  private fun apply(message: StabilizationInbox.Message) {
    val current = switch ?: return
    current.onSetting(message.enabled)
    val notice = current.onTrack(message.hasTrack, message.table)
    update()
    notice?.let(onNotice)
  }

  private fun onFirstStabilizedFrame() {
    // A frame of a table this switch no longer gives (the switch turned off meanwhile, another media) says nothing
    val current = switch ?: return
    if (current.activeTable() == null) return
    current.onStabilizedFrame()?.let(onNotice)
  }

  private fun update() {
    val table: StabilizationTable? = switch?.activeTable()
    stitch.table = table
    onChanged()
  }

  companion object {
    /**
     * Keys of the labels of the stabilisation in the labels of an opening (videoStabilizationLabels of Flutter, the
     * keys of the phone's player): the switch, its states, the notice of a stabilised video and the one of a file
     * without a track
     */
    const val LABEL_STABILIZATION = "stabilization"
    const val LABEL_STABILIZATION_ENABLED = "stabilizationEnabled"
    const val LABEL_STABILIZATION_DISABLED = "stabilizationDisabled"
    const val LABEL_STABILIZATION_ON = "stabilizationOn"
    const val LABEL_STABILIZATION_NO_TRACK = "stabilizationNoTrack"

    // English, for an opening without the labels
    private val DEFAULT_LABELS =
      mapOf(
        LABEL_STABILIZATION to "Stabilise with the camera's gyroscope (experimental)",
        LABEL_STABILIZATION_ENABLED to "Enabled",
        LABEL_STABILIZATION_DISABLED to "Disabled",
        LABEL_STABILIZATION_ON to "Stabilised with the camera's gyroscope",
        LABEL_STABILIZATION_NO_TRACK to "This video has no gyroscope track",
      )

    /** The label [key] of [labels], the English one when Flutter sent none */
    fun label(labels: Map<String, String>, key: String): String =
      labels[key]?.takeIf { it.isNotBlank() } ?: DEFAULT_LABELS.getValue(key)

    /** The text of the button of the panel: the switch and its state */
    fun buttonText(labels: Map<String, String>, enabled: Boolean): String =
      "${label(labels, LABEL_STABILIZATION)}: " +
        label(labels, if (enabled) LABEL_STABILIZATION_ENABLED else LABEL_STABILIZATION_DISABLED)

    /** The text of [notice] */
    fun noticeText(labels: Map<String, String>, notice: StabilizationSwitch.Notice): String =
      when (notice) {
        StabilizationSwitch.Notice.STABILIZED -> label(labels, LABEL_STABILIZATION_ON)
        StabilizationSwitch.Notice.NO_TRACK -> label(labels, LABEL_STABILIZATION_NO_TRACK)
      }
  }
}
