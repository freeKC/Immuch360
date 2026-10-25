package app.alextran.immich.djilink

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.ToneGenerator
import android.util.Log
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * What the drone's sensing said at one moment, as this app reads it: the 72 sectors of the obstacle ring of push 36/8
 * (p2/design-obstacle-ring-2026-10-25.md, 2.2), which come only while the motors run.
 */
data class ObstacleInput(
  /** The 72 sectors in millimetres, null for a sector with no reading; null for a ring of another count */
  val sectorsMm: List<Int?>?,
  /** The nearest distance around the drone, null when no sector reads anything or no ring came */
  val nearestM: Double?,
  /** How old the last ring is, null when none ever came */
  val ageMs: Long?,
  /** The motors bits of the flight data, null when that group is stale or never came */
  val motorsOn: Boolean?,
  /** Flight mode 12, the automatic landing: a landing or a palm catch brings a surface or a hand close */
  val landing: Boolean = false,
  /**
   * When the ring arrived on the phone that read it from the drone, on that phone's clock: how a ring is told apart
   * from the next one. Null to take now minus [ageMs], which is exact where the ring was read but moves with the
   * relay's transit on a receiver ([RingSource.received])
   */
  val ringAtMs: Long? = null,
)

data class ObstacleDecision(
  /** The ring shows: at least one sector is under "Glow from", or it showed less than a second ago */
  val on: Boolean,
  /** The data stopped while the ring showed: its last arcs, white and fading, for five seconds, with no tick */
  val stopped: Boolean,
  /** Offered and fresh. Nothing draws it: no ring never means the way is clear */
  val listening: Boolean,
  /** One even glow all around the picture, no side */
  val even: Boolean,
  /** Nearest first; empty while nothing shows */
  val arcs: List<RingArc>,
  /** The nearest distance of the arcs */
  val nearestM: Double?,
  /** 0 when silent */
  val tickIntervalMs: Int,
  /** Within "Strong glow from": the tick may come with a light tap, on a phone that asks for it */
  val haptic: Boolean,
) {
  companion object {
    val OFF = ObstacleDecision(
      on = false,
      stopped = false,
      listening = false,
      even = true,
      arcs = emptyList(),
      nearestM = null,
      tickIntervalMs = 0,
      haptic = false,
    )
  }
}

/**
 * The decision of the obstacle ring (p2/design-obstacle-ring-2026-10-25.md, 2.1 to 2.5), the same on the phone, on a
 * TV and in the headset, fed with what each device receives and with the phone's choices. Pure, with its own memory:
 * each sector is smoothed (a nearing obstacle at once, a leaving one halfway per ring), joins at "Glow from" and leaves
 * 0.3 m past it; the ring shows at least one second; a ring older than the stale limit (0.6 s on the phone, 1.5 s on
 * a receiver, whose records come through the relay and its pauses) turns the last arcs white for five seconds, unless
 * the motors stopped (the ring stops with them by design).
 *
 * It decides what to draw and how fast to tick, nothing else: it never sends anything to the remote or the drone,
 * never brakes and never changes a setting. The drone's own obstacle avoidance and the remote do that.
 */
class ObstacleAlert {
  companion object {
    const val MIN_ON_MS = 1_000L
    const val PHONE_STALE_MS = 600L
    const val RECEIVER_STALE_MS = 1_500L
    const val STOPPED_MS = 5_000L
  }

  private val smoothed = arrayOfNulls<Double>(ObstacleRing.SECTORS)
  private var smoothedNearest: Double? = null
  private var lastArrivalMs: Long? = null
  private var close: Set<Int> = emptySet()
  private var nearestClose = false
  private var onSinceMs: Long? = null
  private var shown: List<RingArc> = emptyList()
  private var shownEven = true
  private var shownNearest: Double? = null
  private var stoppedSinceMs: Long? = null

  fun reset() {
    forgetRing()
    onSinceMs = null
    shown = emptyList()
    shownEven = true
    shownNearest = null
    stoppedSinceMs = null
  }

  private fun forgetRing() {
    smoothed.fill(null)
    smoothedNearest = null
    lastArrivalMs = null
    close = emptySet()
    nearestClose = false
  }

  fun decide(
    offered: Boolean,
    settings: RingSettings,
    input: ObstacleInput,
    nowMs: Long,
    staleMs: Long = PHONE_STALE_MS,
    mapping: RingMapping = ObstacleRing.MAPPING,
  ): ObstacleDecision {
    if (!offered) {
      reset()
      return ObstacleDecision.OFF
    }
    val ring = settings.clamped()
    val age = input.ageMs
    if (age == null || age > staleMs) {
      return stale(input, nowMs)
    }
    stoppedSinceMs = null
    smooth(input, input.ringAtMs ?: (nowMs - age))
    // A landing brings the ground and a hand close: nothing shows while the drone lands or its motors are off
    val active = input.motorsOn != false && !input.landing
    val sectors = input.sectorsMm
    val even = !ring.directional || sectors == null
    val arcs = if (sectors != null) {
      val distances = smoothed.toList()
      close = ObstacleRing.closeSectors(distances, close, ring.farM)
      if (active) ObstacleRing.arcs(distances, close, ring.copy(directional = !even), mapping) else emptyList()
    } else {
      // A ring of another count: its nearest distance only, as an even glow
      val distance = smoothedNearest
      nearestClose = distance != null &&
        distance <= (if (nearestClose) ring.farM + ObstacleRing.HYSTERESIS_M else ring.farM)
      if (active && nearestClose && distance != null) listOf(ObstacleRing.arc(null, distance, ring)) else emptyList()
    }
    val since = onSinceMs
    if (arcs.isEmpty()) {
      if (since != null && nowMs - since < MIN_ON_MS) {
        // Once shown, at least a second: the last arcs, with no tick
        return ObstacleDecision(
          on = true,
          stopped = false,
          listening = true,
          even = shownEven,
          arcs = shown,
          nearestM = shownNearest,
          tickIntervalMs = 0,
          haptic = false,
        )
      }
      onSinceMs = null
      shown = emptyList()
      shownNearest = null
      return ObstacleDecision.OFF.copy(listening = true)
    }
    if (since == null) {
      onSinceMs = nowMs
    }
    val nearest = arcs.minOf { it.distanceM }
    shown = arcs
    shownEven = even
    shownNearest = nearest
    val tick = ObstacleRing.tickIntervalMs(nearest, ring, even)
    return ObstacleDecision(
      on = true,
      stopped = false,
      listening = true,
      even = even,
      arcs = arcs,
      nearestM = nearest,
      tickIntervalMs = tick,
      haptic = tick > 0 && nearest <= ring.nearM,
    )
  }

  /** The ring went stale: the last arcs turn white and fade for five seconds, unless the motors are reported off */
  private fun stale(input: ObstacleInput, nowMs: Long): ObstacleDecision {
    forgetRing()
    if (onSinceMs != null) {
      onSinceMs = null
      stoppedSinceMs = if (input.motorsOn == false) null else nowMs
    }
    val since = stoppedSinceMs
    if (since != null && input.motorsOn != false && nowMs - since < STOPPED_MS) {
      val fade = 1.0 - (nowMs - since).toDouble() / STOPPED_MS
      return ObstacleDecision.OFF.copy(
        stopped = true,
        even = shownEven,
        arcs = shown.map { it.copy(opacity = ObstacleRing.STOPPED_OPACITY * fade, argb = ObstacleRing.WHITE) },
        nearestM = shownNearest,
      )
    }
    stoppedSinceMs = null
    shown = emptyList()
    shownNearest = null
    return ObstacleDecision.OFF
  }

  /**
   * Each sector keeps min(new, half new and half its last value) once per ring, not once per tick: a ring is the one
   * seen at the last tick when it arrived at the same moment on the phone that read it
   */
  private fun smooth(input: ObstacleInput, arrivalMs: Long) {
    if (arrivalMs == lastArrivalMs) {
      return
    }
    lastArrivalMs = arrivalMs
    val sectors = input.sectorsMm
    for (sector in smoothed.indices) {
      smoothed[sector] = step(sectors?.getOrNull(sector)?.let { it / 1_000.0 }, smoothed[sector])
    }
    smoothedNearest = step(input.nearestM, smoothedNearest)
  }

  private fun step(new: Double?, previous: Double?): Double? = when {
    // No reading is never clear and never drawn: the sector leaves at once
    new == null -> null
    previous == null -> new
    else -> min(new, 0.5 * new + 0.5 * previous)
  }
}

/** What the ring reads from the values of the source in use: its sectors, its age, the motors and the landing */
fun obstacleInputOf(values: TelemetryValues?): ObstacleInput {
  val ring = values?.obstacles
  val flight = values?.flight?.takeIf { !it.stale }?.value
  return ObstacleInput(
    sectorsMm = ring?.value?.sectorsMm,
    nearestM = ring?.value?.nearestM,
    ageMs = ring?.ageMs,
    motorsOn = flight?.motorsOn,
    landing = flight?.mode == TelemetryFields.MODE_AUTOMATIC_LANDING,
  )
}

/** The made up ring of "Show a sample" at [tMs] from its start, fresh, motors running; null once it is over */
fun obstacleSampleInput(tMs: Long, mapping: RingMapping = ObstacleRing.MAPPING): ObstacleInput? {
  val sectors = ObstacleRing.sample(tMs, mapping) ?: return null
  return ObstacleInput(
    sectorsMm = sectors,
    nearestM = sectors.filterNotNull().minOrNull()?.let { it / 1_000.0 },
    ageMs = 0,
    motorsOn = true,
  )
}

/**
 * The source in use at one tick of the controller: its values (aged on a receiver, for the frame), what the ring reads
 * from them, and on a receiver the phone's choices relayed with them
 */
data class RingSource(
  val values: TelemetryValues?,
  val input: ObstacleInput,
  /** A phone's relay, not the cable or a capture being played */
  val receiving: Boolean,
  /** The phone's choices for the ring; null on the phone itself, and from a phone of an earlier build */
  val relayed: RelayObstacleRing?,
) {
  companion object {
    /** The cable or a capture being played: the ring was read here, its age is exact */
    fun local(values: TelemetryValues?): RingSource = RingSource(values, obstacleInputOf(values), false, null)

    /**
     * A phone's relay: its last [record] (null before the first) [sinceMs] after it arrived here. The ring is told
     * apart by when it arrived on the phone (the record's clock minus the ring's age there), which does not move with
     * the transit of each record as now minus the aged age does (p2/review-obstacle-ring-2026-10-25.md, minor 5)
     */
    fun received(record: RelayTelemetryRecord?, sinceMs: Long): RingSource {
      if (record == null) {
        return RingSource(null, obstacleInputOf(null), true, null)
      }
      val values = record.aged(sinceMs)
      val ringAtMs = record.values.obstacles?.let { record.phoneNs / 1_000_000 - it.ageMs }
      return RingSource(values, obstacleInputOf(values).copy(ringAtMs = ringAtMs), true, record.obstacleRing)
    }
  }
}

/**
 * This device's own choices for the ring, as Flutter sent them. [offered] on a phone is the pilot's switch; on a TV or a
 * headset it is the ring on that screen, which shows only when the phone offers it too.
 */
data class RingChoices(
  val offered: Boolean = false,
  val settings: RingSettings = RingSettings(),
  /** "Vibrate with the tick", on a phone */
  val haptic: Boolean = false,
)

/** What one tick feeds the decision with ([ringTickInputs]) */
data class RingTickInputs(
  val offered: Boolean,
  val settings: RingSettings,
  val input: ObstacleInput,
  val staleMs: Long,
  /** When "Show a sample" started, if it still runs after this tick; null when none runs */
  val sampleStartMs: Long?,
  /** The sample ended at this tick, its eight seconds over or the motors started: the decision starts afresh */
  val sampleEnded: Boolean,
  /** The tick may tap: this phone asked for it. A receiver never vibrates */
  val tapAllowed: Boolean,
)

/**
 * The inputs of [ObstacleAlert.decide] at one tick, from the source in use, this device's choices and the sample
 * (p2/review-obstacle-ring-2026-10-25.md, major 1 and minor 4). On a receiver the phone's record says whether the ring
 * is offered, its distances and its side, so that every screen draws what the phone draws (a phone of an earlier build
 * sends none: no ring), and the stale limit is the relay's; the receiver's own switch can only turn it off there. "Show a sample" runs eight seconds, and ends at once when
 * the motors start: a made up obstacle is never drawn in flight, and the real ring is decided again at that tick.
 */
fun ringTickInputs(source: RingSource, choices: RingChoices, sampleStartMs: Long?, nowMs: Long): RingTickInputs {
  val relayed = source.relayed
  val offered = if (source.receiving) (relayed?.offered ?: false) && choices.offered else choices.offered
  val settings = if (source.receiving) relayed?.settings() ?: RingSettings() else choices.settings
  val sample = sampleStartMs
    ?.takeIf { source.input.motorsOn != true }
    ?.let { obstacleSampleInput(nowMs - it) }
  return RingTickInputs(
    offered = sample != null || offered,
    settings = settings,
    input = sample ?: source.input,
    staleMs = if (source.receiving) ObstacleAlert.RECEIVER_STALE_MS else ObstacleAlert.PHONE_STALE_MS,
    sampleStartMs = if (sample != null) sampleStartMs else null,
    sampleEnded = sampleStartMs != null && sample == null,
    tapAllowed = !source.receiving && choices.haptic,
  )
}

/** What the ring decided at one tick, and whether the tick taps */
data class RingTick(val decision: ObstacleDecision, val tap: Boolean)

/**
 * One device's obstacle ring from tick to tick (the controller's, every 50 ms while a picture screen is in front): the
 * decision with its memory, "Show a sample", and the tap. Pure apart from that memory, so that the glue between the
 * source, the phone's relayed choices, this device's own and the sample is tested.
 */
class ObstacleRingTicker {
  private val alert = ObstacleAlert()

  /** When "Show a sample" started on this device, null when none runs */
  var sampleStartMs: Long? = null
    private set

  /** "Show a sample": eight seconds of a made up ring, refused while the motors run */
  fun startSample(source: RingSource, nowMs: Long): Boolean {
    if (source.input.motorsOn == true) {
      return false
    }
    alert.reset()
    sampleStartMs = nowMs
    return true
  }

  /** No picture screen in front any more: nothing of the ring or of a sample is kept */
  fun reset() {
    alert.reset()
    sampleStartMs = null
  }

  fun tick(source: RingSource, choices: RingChoices, nowMs: Long): RingTick {
    val inputs = ringTickInputs(source, choices, sampleStartMs, nowMs)
    if (inputs.sampleEnded) {
      alert.reset()
    }
    sampleStartMs = inputs.sampleStartMs
    val decision = alert.decide(inputs.offered, inputs.settings, inputs.input, nowMs, inputs.staleMs)
    return RingTick(decision, tap = inputs.tapAllowed && decision.haptic)
  }
}

/** Plays one short tick */
fun interface ObstacleBeeper {
  fun beep()
}

/**
 * The rhythm of the tick (p2/design-obstacle-ring-2026-10-25.md, 3): one tick every [ObstacleDecision.tickIntervalMs],
 * only while the ring asks for it, its sound or its tap on, and a screen with the picture in front on this device.
 * With the tap asked, each tick also calls [tap]. Pure apart from the beeper and the tap, so that the rhythm is tested.
 */
class ObstacleTone(private val beeper: ObstacleBeeper, private val tap: () -> Unit = {}) {
  companion object {
    const val TEST_TICKS = 3
    const val TEST_INTERVAL_MS = 300L
  }

  private var lastTickMs: Long? = null

  /**
   * "Play the sound": [TEST_TICKS] ticks [TEST_INTERVAL_MS] apart, each handed to [schedule] with its delay (the
   * controller's handler), whatever the ring and the sound switch say: it is how the pilot checks the volume
   */
  fun playTest(schedule: (delayMs: Long, tick: () -> Unit) -> Unit) {
    for (index in 0 until TEST_TICKS) {
      schedule(index * TEST_INTERVAL_MS) { beeper.beep() }
    }
  }

  /** Called every few tens of milliseconds; [intervalMs] 0 is silence */
  fun update(intervalMs: Int, soundOn: Boolean, screenShown: Boolean, nowMs: Long, tapOn: Boolean = false) {
    if (intervalMs <= 0 || !(soundOn || tapOn) || !screenShown) {
      lastTickMs = null
      return
    }
    val last = lastTickMs
    if (last == null || nowMs - last >= intervalMs) {
      lastTickMs = nowMs
      if (soundOn) {
        beeper.beep()
      }
      if (tapOn) {
        tap()
      }
    }
  }
}

/** The tick's waveform, made in code: a 1.6 kHz sine of 30 ms with 5 ms ramps, 16 bit mono */
object TickSound {
  const val SAMPLE_RATE = 44_100
  const val TICK_MS = 30
  const val RAMP_MS = 5
  const val FREQUENCY_HZ = 1_600.0

  /** At 60 % of the media volume: softer than the beep it replaces */
  const val VOLUME = 0.6f

  fun samples(): ShortArray {
    val count = SAMPLE_RATE * TICK_MS / 1_000
    val ramp = SAMPLE_RATE * RAMP_MS / 1_000
    return ShortArray(count) { index ->
      val envelope = min(1.0, min(index.toDouble() / ramp, (count - 1 - index).toDouble() / ramp))
      (sin(2 * PI * FREQUENCY_HZ * index / SAMPLE_RATE) * envelope * Short.MAX_VALUE).roundToInt().toShort()
    }
  }
}

/**
 * The tick itself, on the media stream, the volume DJI's own beeps follow, which the volume keys set while the live
 * screen is in front: our own waveform in a static [AudioTrack], made on the first tick; a short tone of
 * [ToneGenerator] when no track can be made. Released with [release].
 */
class TickBeeper : ObstacleBeeper {
  companion object {
    private const val TAG = "ObstacleTone"
  }

  private var track: AudioTrack? = null
  private var trackFailed = false
  private var generator: ToneGenerator? = null

  override fun beep() {
    val played = (track ?: makeTrack())?.let { audio ->
      runCatching {
        audio.stop()
        audio.reloadStaticData()
        audio.play()
      }.isSuccess
    } ?: false
    if (!played) {
      fallback()
    }
  }

  private fun makeTrack(): AudioTrack? {
    if (trackFailed) {
      return null
    }
    val samples = TickSound.samples()
    return runCatching {
      AudioTrack.Builder()
        .setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build(),
        )
        .setAudioFormat(
          AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(TickSound.SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build(),
        )
        .setTransferMode(AudioTrack.MODE_STATIC)
        .setBufferSizeInBytes(samples.size * 2)
        .build()
        .also { made ->
          made.write(samples, 0, samples.size)
          made.setVolume(TickSound.VOLUME)
        }
    }.onFailure {
      trackFailed = true
      Log.w(TAG, "no audio track for the tick: ${it.javaClass.simpleName}")
    }.getOrNull()?.also { track = it }
  }

  private fun fallback() {
    val tone = generator ?: runCatching {
      ToneGenerator(AudioManager.STREAM_MUSIC, (ToneGenerator.MAX_VOLUME * TickSound.VOLUME).roundToInt())
    }
      .onFailure { Log.w(TAG, "no tone generator: ${it.javaClass.simpleName}") }
      .getOrNull()
      ?.also { generator = it }
      ?: return
    runCatching { tone.startTone(ToneGenerator.TONE_PROP_BEEP, TickSound.TICK_MS) }
  }

  fun release() {
    track?.let { runCatching { it.release() } }
    track = null
    trackFailed = false
    generator?.let { runCatching { it.release() } }
    generator = null
  }
}
