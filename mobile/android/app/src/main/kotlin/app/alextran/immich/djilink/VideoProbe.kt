package app.alextran.immich.djilink

/**
 * What a video payload looks like, without naming a codec.
 *
 * Public work on cabled DJI controllers expects an H.264 elementary stream on this path, which gives one thing to look
 * for: the Annex B start code. This probe reports what it finds, counts the unit types it sees and says whether
 * parameter sets appeared. It never concludes: the verdict stays [ProbeVerdict.START_CODES_SEEN] until a decoder has
 * produced a picture on real hardware.
 */
enum class ProbeVerdict {
  /** No video payload arrived at all */
  NO_DATA,

  /** Payloads arrived and none of them starts with an Annex B start code */
  NO_START_CODES,

  /** Start codes are there; which codec it is stays an open question until a decoder says so */
  START_CODES_SEEN,
}

data class VideoProbeReport(
  val verdict: ProbeVerdict,
  val payloads: Long,
  val payloadsStartingWithStartCode: Long,
  val startCodesSeen: Long,
  /** Count per five bit unit type as read from the byte after a start code, no codec assumed */
  val unitTypes: Map<Int, Long>,
  /** Whether units 7 and 8, which are the parameter sets of H.264, were seen */
  val sawH264ParameterSets: Boolean,
  /** Whether units 32, 33 and 34, the parameter sets of H.265, were seen */
  val sawH265ParameterSets: Boolean,
)

class VideoProbe {
  private var payloads = 0L
  private var payloadsWithStartCode = 0L
  private var startCodes = 0L
  private val unitTypes = linkedMapOf<Int, Long>()
  private val h265Types = linkedMapOf<Int, Long>()

  fun offer(payload: ByteArray) {
    payloads += 1
    if (startsWithStartCode(payload)) {
      payloadsWithStartCode += 1
    }
    var index = 0
    while (index + 3 < payload.size) {
      val three = payload[index].toInt() == 0 && payload[index + 1].toInt() == 0 && payload[index + 2].toInt() == 1
      val four = payload[index].toInt() == 0 &&
        payload[index + 1].toInt() == 0 &&
        payload[index + 2].toInt() == 0 &&
        payload[index + 3].toInt() == 1
      if (!three && !four) {
        index += 1
        continue
      }
      val header = index + if (four) 4 else 3
      if (header >= payload.size) {
        break
      }
      startCodes += 1
      val byte = payload[header].toInt() and 0xFF
      // Read both ways and kept apart: five low bits as one family packs a unit type, six bits as another does
      val five = byte and 0x1F
      val six = (byte shr 1) and 0x3F
      unitTypes[five] = (unitTypes[five] ?: 0) + 1
      h265Types[six] = (h265Types[six] ?: 0) + 1
      index = header + 1
    }
  }

  fun report(): VideoProbeReport = VideoProbeReport(
    verdict = when {
      payloads == 0L -> ProbeVerdict.NO_DATA
      startCodes == 0L -> ProbeVerdict.NO_START_CODES
      else -> ProbeVerdict.START_CODES_SEEN
    },
    payloads = payloads,
    payloadsStartingWithStartCode = payloadsWithStartCode,
    startCodesSeen = startCodes,
    unitTypes = unitTypes.toSortedMap().toMap(),
    sawH264ParameterSets = unitTypes.containsKey(7) && unitTypes.containsKey(8),
    sawH265ParameterSets = h265Types.keys.containsAll(listOf(32, 33, 34)),
  )

  fun reset() {
    payloads = 0
    payloadsWithStartCode = 0
    startCodes = 0
    unitTypes.clear()
    h265Types.clear()
  }

  companion object {
    fun startsWithStartCode(payload: ByteArray): Boolean {
      if (payload.size >= 4 &&
        payload[0].toInt() == 0 &&
        payload[1].toInt() == 0 &&
        payload[2].toInt() == 0 &&
        payload[3].toInt() == 1
      ) {
        return true
      }
      return payload.size >= 3 &&
        payload[0].toInt() == 0 &&
        payload[1].toInt() == 0 &&
        payload[2].toInt() == 1
    }
  }
}
