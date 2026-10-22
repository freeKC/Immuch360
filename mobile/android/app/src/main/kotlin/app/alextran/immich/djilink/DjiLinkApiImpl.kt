package app.alextran.immich.djilink

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import java.util.concurrent.Executors

/**
 * What Flutter asks of the link. Every call is a question about what is there, or a capture control. None of them can
 * move an aircraft: there is no method here that sends anything, and the transport writes nothing but its own one
 * byte liveness probe.
 */
class DjiLinkApiImpl(private val context: Context) : DjiLinkApi {
  companion object {
    private const val TAG = "DjiLinkApi"

    /**
     * The entry that puts this application in the Android chooser when a DJI accessory is plugged in. It ships
     * disabled and is only enabled while the diagnostics switch is on, so a pilot who never asked for it never sees
     * this application offered for a cable, and it never competes with the DJI application on a phone.
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

  private val controller = DjiLinkController.of(context)
  private val worker = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "DjiLinkWork").apply { isDaemon = true }
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
      callback(
        Result.success(
          DjiLinkExport(
            ok = result.ok,
            bytes = result.bytes,
            binPath = result.binPath,
            indexPath = result.indexPath,
            headerPath = result.headerPath,
            sha256 = result.sha256,
            error = result.error,
          )
        )
      )
    }
  }

  override fun replayCapture(path: String, callback: (Result<DjiLinkReplayResult>) -> Unit) {
    worker.execute {
      val replayed = runCatching { controller.replay(path) }
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
            error = null,
            counters = DjiLinkCounters(
              envelopeFrames = result.envelopes.frames,
              envelopeBytes = result.envelopes.frameBytes,
              payloadBytes = result.envelopes.payloadBytes,
              discardedBytes = result.envelopes.discardedBytes + result.control.discardedBytes,
              resynchronisations = result.envelopes.resynchronisations + result.control.resynchronisations,
              unknownChannelFrames = result.envelopes.unknownChannelFrames,
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
              verdict = when (result.probe.verdict) {
                ProbeVerdict.NO_DATA -> DjiLinkProbeVerdict.NO_DATA
                ProbeVerdict.NO_START_CODES -> DjiLinkProbeVerdict.NO_START_CODES
                ProbeVerdict.START_CODES_SEEN -> DjiLinkProbeVerdict.START_CODES_SEEN
              },
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
}
