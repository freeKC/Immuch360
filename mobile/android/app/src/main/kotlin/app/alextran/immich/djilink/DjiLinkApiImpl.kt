package app.alextran.immich.djilink

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * What Flutter asks of the link. Every call is a question about what is there, a capture control, a capture to play,
 * a choice of the page (the decoder, the hardware profile), the relay to headsets or the reception of a phone's relay.
 * None of them can move an aircraft: there is no method here that sends anything to the remote, the transport writes
 * nothing but its own one byte liveness probe, and the relay carries the picture and the values toward the headsets
 * only.
 */
class DjiLinkApiImpl(private val context: Context) : DjiLinkApi {
  companion object {
    private const val TAG = "DjiLinkApi"

    /**
     * The entry that puts this application in the Android chooser when a DJI accessory is plugged in. It ships
     * disabled and is enabled while a link runs, or when the pilot asked for it ([AttachEntryPolicy]), so a pilot who
     * never asked for it never sees this application offered for a cable, and it never competes with the DJI
     * application on a phone.
     */
    fun setAttachEntryEnabled(context: Context, enabled: Boolean) {
      val component = ComponentName(context, DjiLinkAttachActivity::class.java)
      val wanted = if (enabled) {
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED
      } else {
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED
      }
      runCatching {
        context.packageManager.setComponentEnabledSetting(component, wanted, PackageManager.DONT_KILL_APP)
      }.onFailure { Log.w(TAG, "the attach entry could not be switched: ${it.javaClass.simpleName}") }
    }
  }

  // Made on the first call of the page, not when the engine starts: a pilot who never opens the page holds nothing.
  // The import page lists the plugged accessories without it.
  private val controller by lazy { DjiLinkController.of(context) }
  private val main = Handler(Looper.getMainLooper())

  /** The answers that keep the attach entry when no link runs; read without making the controller */
  private val attachPreferences by lazy { AttachEntryPreferences(SharedPreferencesStore(context)) }
  private val pickerRequests = AtomicInteger()
  private val worker by lazy {
    Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "DjiLinkWork").apply { isDaemon = true } }
  }

  override fun readEnvironment(): DjiLinkEnvironment {
    controller.readEnvironment()
    return controller.environmentPigeon()
  }

  override fun start() {
    setAttachEntryEnabled(context, true)
    controller.start()
  }

  override fun stop() {
    // The entry lives as long as the link does: the page, or the relay that keeps the cable for a headset. The
    // controller disables it where the link really ends, here or later (Stop in the notification, the app swiped
    // away), so that a pilot who left the page and sends nothing is not offered this application for a cable.
    controller.stop()
  }

  override fun retry() {
    controller.retry()
  }

  override fun snapshot(): DjiLinkSnapshot = controller.snapshot()

  override fun startCapture() {
    controller.startCapture()
  }

  override fun stopCapture() {
    controller.stopCapture()
  }

  override fun clearCapture() {
    controller.clearCapture()
  }

  override fun exportCapture(notes: DjiLinkExportNotes, callback: (Result<DjiLinkExport>) -> Unit) {
    worker.execute {
      val result = controller.exportCapture(
        linkedMapOf(
          "cable" to notes.cable,
          "port" to notes.port,
          "remoteState" to notes.remoteState,
          "aircraftState" to notes.aircraftState,
          "note" to notes.note,
        )
      )
      callback(Result.success(result.toPigeon()))
    }
  }

  /** On the same worker as the capture's export: two taps never write at once, the second answers "already saved" */
  override fun exportReception(callback: (Result<DjiLinkExport>) -> Unit) {
    worker.execute {
      val result = runCatching { controller.exportReception() }.getOrElse {
        CaptureExport.Result(ok = false, bytes = 0, error = it.message ?: it.javaClass.simpleName)
      }
      callback(Result.success(result.toPigeon()))
    }
  }

  override fun setFrameStream(on: Boolean) {
    controller.setFrameStream(on)
  }

  override fun setObstacleRing(settings: DjiObstacleRingSettings) {
    // The activity's window taps with the tick on a phone, through performHapticFeedback: no permission
    controller.setObstacleRing(settings, context as? Activity)
  }

  override fun setLowestDelay(on: Boolean) {
    controller.setLowestDelay(on)
  }

  override fun setRelayQuality(quality: DjiRelayQuality) {
    controller.setRelayQuality(
      when (quality) {
        DjiRelayQuality.AUTOMATIC -> RelayQuality.AUTOMATIC
        DjiRelayQuality.FULL -> RelayQuality.FULL
        DjiRelayQuality.STEADY -> RelayQuality.STEADY
      },
    )
  }

  override fun relayQuality(): DjiRelayQuality = controller.relayQuality().toPigeon()

  override fun playObstacleTest() {
    controller.playObstacleTest()
  }

  override fun showObstacleSample(): Boolean = controller.showObstacleSample()

  override fun hasVibrator(): Boolean = runCatching {
    val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
    } else {
      @Suppress("DEPRECATION")
      context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
    }
    vibrator?.hasVibrator() ?: false
  }.getOrDefault(false)

  override fun mediaVolumeOff(): Boolean = controller.mediaVolumeOff()

  override fun replayCapture(
    path: String,
    headerCrcSeed: Long?,
    frameCrcSeed: Long?,
    callback: (Result<DjiLinkReplayResult>) -> Unit,
  ) {
    worker.execute {
      val replayed = runCatching { controller.replay(path, headerCrcSeed?.toInt(), frameCrcSeed?.toInt()) }
      val failure = replayed.exceptionOrNull()
      if (failure != null) {
        callback(
          Result.success(
            DjiLinkReplayResult(
              ok = false,
              readsReplayed = 0,
              bytesReplayed = 0,
              usedIndex = false,
              error = failure.message ?: failure.javaClass.simpleName,
              opens = 0,
              counters = null,
              channels = null,
              frames = null,
              telemetry = null,
              video = null,
            )
          )
        )
        return@execute
      }
      val result = replayed.getOrThrow()
      callback(
        Result.success(
          DjiLinkReplayResult(
            ok = true,
            readsReplayed = result.readsReplayed.toLong(),
            bytesReplayed = result.bytesReplayed,
            usedIndex = result.usedIndex,
            opens = result.opens.toLong(),
            error = null,
            crc = result.crc.toPigeon(),
            counters = DjiLinkCounters(
              envelopeFrames = result.envelopes.frames,
              envelopeBytes = result.envelopes.frameBytes,
              payloadBytes = result.envelopes.payloadBytes,
              discardedBytes = result.envelopes.discardedBytes + result.control.discardedBytes,
              resynchronisations = result.envelopes.resynchronisations + result.control.resynchronisations,
              unknownChannelFrames = result.envelopes.unknownChannelFrames,
              unknownChannelRejections = result.envelopes.unknownChannelRejections,
              oversizeRejections = result.envelopes.oversizeRejections,
              incompleteTimeouts = result.envelopes.incompleteTimeouts,
              controlFrames = result.control.frames,
              headerCrcFailures = result.control.headerCrcFailures,
              frameCrcFailures = result.control.frameCrcFailures,
              lengthRejections = result.control.lengthRejections,
              unsupportedEncryption = result.control.unsupportedEncryption,
              knownPairs = result.router.knownPairs,
              unknownPairs = result.router.unknownPairs,
              aircraftSideFrames = result.router.aircraftSideFrames,
              controllerSideFrames = result.router.controllerSideFrames,
              ambiguousSideFrames = result.router.ambiguousSideFrames,
              keepAliveExceptions = result.router.keepAliveExceptions,
              paddingBytes = result.envelopes.paddingBytes,
            ),
            channels = result.channels.map {
              DjiLinkChannel(
                channel = it.channel.toLong(),
                role = it.role.name.lowercase(),
                envelopes = it.envelopes,
                bytes = it.bytes,
                largestPayload = it.largestPayload.toLong(),
                lastArrivalMs = it.lastArrivalMs,
                firstArrivalMs = it.firstArrivalMs,
                cameraType = null,
              )
            },
            frames = result.frames.map {
              DjiLinkFrame(
                atMs = it.atMs,
                channel = it.channel.toLong(),
                commandSet = it.commandSet.toLong(),
                commandId = it.commandId.toLong(),
                isAcknowledgement = it.isAcknowledgement,
                ackPolicy = it.ackPolicy.toLong(),
                senderType = it.senderType.toLong(),
                receiverType = it.receiverType.toLong(),
                sequence = it.sequence.toLong(),
                length = it.length.toLong(),
                encryption = it.encryption.toLong(),
                preview = it.preview,
              )
            },
            telemetry = result.telemetry.map {
              DjiLinkTelemetryRow(
                commandSet = it.commandSet.toLong(),
                commandId = it.commandId.toLong(),
                count = it.count,
                lastLength = it.lastLength.toLong(),
                ratePerSecond = it.ratePerSecond,
                preview = it.preview,
                name = it.name,
              )
            },
            video = DjiLinkVideo(
              verdict = result.probe.verdict.toPigeon(),
              payloads = result.probe.payloads,
              payloadsStartingWithStartCode = result.probe.payloadsStartingWithStartCode,
              startCodesSeen = result.probe.startCodesSeen,
              unitTypes = result.probe.unitTypes.entries.joinToString(" ") { "${it.key}:${it.value}" },
              sawH264ParameterSets = result.probe.sawH264ParameterSets,
              sawH265ParameterSets = result.probe.sawH265ParameterSets,
              channels = result.video.map {
                DjiLinkVideoChannel(
                  channel = it.channel.toLong(),
                  fragments = it.fragments,
                  bytes = it.bytes,
                  largestFragment = it.largestFragment.toLong(),
                  gaps = it.gaps,
                  longestGapMs = it.longestGapMs,
                )
              },
            ),
          )
        )
      )
    }
  }

  override fun setDecoderChoice(choice: DjiLinkDecoderChoice) {
    controller.setDecoderChoice(
      when (choice) {
        DjiLinkDecoderChoice.AUTOMATIC -> DecoderChoice.AUTOMATIC
        DjiLinkDecoderChoice.HARDWARE -> DecoderChoice.HARDWARE
        DjiLinkDecoderChoice.SOFTWARE -> DecoderChoice.SOFTWARE
      }
    )
  }

  override fun listCaptures(callback: (Result<List<DjiLinkCaptureFile>>) -> Unit) {
    worker.execute {
      val files = runCatching { controller.listCaptures() }.getOrDefault(emptyList())
      callback(Result.success(files.map { it.toPigeon() }))
    }
  }

  /**
   * The system picker with several files at once; the .bin and the .idx.csv of one capture are paired by their names.
   * The picker belongs to the activity that made this bridge, the app's own.
   */
  override fun chooseCaptureFiles(callback: (Result<DjiLinkCaptureFile?>) -> Unit) {
    val activity = context as? ComponentActivity
    if (activity == null) {
      callback(Result.success(null))
      return
    }
    main.post {
      val key = "djilink-capture-files-${pickerRequests.incrementAndGet()}"
      lateinit var launcher: androidx.activity.result.ActivityResultLauncher<Array<String>>
      launcher = activity.activityResultRegistry.register(key, ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        launcher.unregister()
        worker.execute {
          val chosen = runCatching { CaptureFiles.pairChosen(context, uris) }.getOrNull()
          callback(Result.success(chosen?.toPigeon()))
        }
      }
      runCatching { launcher.launch(arrayOf("*/*")) }.onFailure {
        launcher.unregister()
        callback(Result.success(null))
      }
    }
  }

  override fun playCapture(
    binUri: String,
    indexUri: String,
    startAtMs: Long,
    loop: Boolean,
    callback: (Result<String?>) -> Unit,
  ) {
    // The page session of the request, read on the main thread where the page closes: if it closes while the files
    // are read on the worker, the capture is not played
    val session = controller.pageSession
    worker.execute {
      val outcome = runCatching {
        controller.playCapture(binUri, indexUri, startAtMs, session = session, loop = loop)
      }.getOrElse { "unreadable" }
      callback(Result.success(outcome))
    }
  }

  override fun startRelay(start: DjiRelayStart, callback: (Result<Long>) -> Unit) {
    val texts = DjiLinkRelayTexts(start.notificationTitle, start.notificationText, start.stopLabel, start.channelName)
    // The page session of the request, read on the main thread where the page closes: a page that closes while the
    // socket is being bound on the worker leaves no relay behind it
    val session = controller.pageSession
    // The socket is bound on the worker, never on the main thread
    worker.execute {
      val port = runCatching {
        controller.startRelay(
          start.code,
          texts,
          start.phoneName,
          start.phoneId,
          session,
          start.screenCodes.map { RelayScreenCode(it.id, it.code) },
        )
      }.getOrElse {
        Log.w(TAG, "the relay did not start: ${it.javaClass.simpleName}")
        0
      }
      callback(Result.success(port.toLong()))
    }
  }

  override fun stopRelay() {
    controller.stopRelay()
  }

  override fun setRelayCode(code: String) {
    controller.setRelayCode(code)
  }

  override fun setRelayScreenCodes(codes: List<DjiRelayScreenCode>) {
    controller.setRelayScreenCodes(codes.map { RelayScreenCode(it.id, it.code) })
  }

  override fun updateRelayNotification(text: String) {
    controller.updateRelayNotification(text)
  }

  override fun connectRelay(host: String, port: Long, code: String, phoneId: String?, headsetName: String): String? =
    controller.connectRelay(host, port.toInt(), code, phoneId, headsetName)

  override fun disconnectRelay() {
    controller.disconnectRelay()
  }

  override fun openFlightView(labels: Map<String, String>): Boolean = controller.openFlightView(labels)

  override fun stopPlayback() {
    controller.stopPlayback()
  }

  override fun setOpenOnPlug(on: Boolean) {
    attachPreferences.openOnPlug = on
    applyAttachEntry()
  }

  override fun openOnPlug(): Boolean = attachPreferences.openOnPlug

  override fun setLiveSettingOn(on: Boolean) {
    attachPreferences.settingOn = on
    applyAttachEntry()
  }

  /** The entry follows the two answers at once, unless a link runs, which keeps it until it ends */
  private fun applyAttachEntry() {
    val linkRunning = DjiLinkController.existing()?.isStarted == true
    setAttachEntryEnabled(context, attachPreferences.entryEnabled(linkRunning))
  }

  override fun takeAttachLaunch(): Boolean = AttachLaunch.take()

  override fun bindProfile(profileId: String?) {
    controller.bindProfile(profileId)
  }

  override fun profiles(): List<DjiLinkProfile> =
    controller.bindableProfiles().map { it.toPigeon(controller.runningDevice) }

  /** The accessory list of the system: strings only, no serial, no permission, nothing opened, no link owner made */
  override fun pluggedAccessories(): List<DjiLinkPluggedAccessory> {
    val usb = context.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return emptyList()
    val listed = runCatching { usb.accessoryList?.toList() ?: emptyList() }.getOrDefault(emptyList())
    return listed.map {
      DjiLinkPluggedAccessory(
        manufacturer = it.manufacturer,
        model = it.model,
        description = it.description,
        version = it.version,
      )
    }
  }
}

private fun CaptureExport.Result.toPigeon(): DjiLinkExport = DjiLinkExport(
  ok = ok,
  bytes = bytes,
  binPath = binPath,
  indexPath = indexPath,
  headerPath = headerPath,
  sha256 = sha256,
  error = error,
  headerOnly = headerOnly,
  repeated = repeated,
  nothing = nothing,
  controlBinPath = controlBinPath,
)

private fun CaptureFile.toPigeon(): DjiLinkCaptureFile = DjiLinkCaptureFile(
  name = name,
  binUri = binUri,
  indexUri = indexUri,
  bytes = bytes,
  modifiedMs = modifiedMs,
  origin = origin,
)
