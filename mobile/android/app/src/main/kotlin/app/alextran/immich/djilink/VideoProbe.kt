package app.alextran.immich.djilink

/**
 * What a video payload looks like.
 *
 * The probe reports what it finds after an Annex B start code, counts the unit types it sees and says whether
 * parameter sets appeared. It names a codec only once [CodecDetector] has recognised one from the stream itself: H.265
 * from its parameter sets or from the delimiter signature of the 23 October 2026 capture (p2/capture-2026-10-23.md,
 * section 4), H.264 from its own sequence parameter set. Until then the verdict stays [ProbeVerdict.START_CODES_SEEN].
 */
enum class ProbeVerdict {
  /** No video payload arrived at all */
  NO_DATA,

  /** Payloads arrived and none of them starts with an Annex B start code */
  NO_START_CODES,

  /** Start codes are there; which codec it is stays an open question */
  START_CODES_SEEN,

  /** H.265, recognised from its parameter sets or from the delimiter signature */
  H265,

  /** H.264, recognised from its sequence parameter set; not decoded in this stage */
  H264,
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
  /** Fed with the access units of the video channel by the router; the codec it settles on is the probe's verdict */
  val detector = CodecDetector()

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
      detector.codec == VideoCodec.H265 -> ProbeVerdict.H265
      detector.codec == VideoCodec.H264 -> ProbeVerdict.H264
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
    detector.reset()
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

enum class VideoCodec {
  UNKNOWN,
  H265,
  H264,
}

/** How the codec was recognised */
enum class CodecEvidence {
  NONE,

  /** A VPS, an SPS and a PPS with layer 0 headers, and an SPS that gives a plausible size */
  PARAMETER_SETS,

  /** [CodecDetector.SIGNATURE_UNITS] units in a row that open with the H.265 delimiter 46 01, before any parameter set */
  DELIMITER_SIGNATURE,

  /** An H.264 sequence parameter set that parses, and a picture parameter set */
  H264_PARAMETER_SETS,
}

/**
 * A complete H.265 stream description: the VPS, SPS and PPS NAL units (header included, start code excluded) and what
 * our reader made of the SPS.
 */
class StreamDescription(val vps: ByteArray, val sps: ByteArray, val pps: ByteArray, val info: HevcSps) {
  /** The three sets each behind a four byte start code, which is what a decoder takes as its configuration */
  fun configuration(): ByteArray {
    val code = byteArrayOf(0, 0, 0, 1)
    return code + vps + code + sps + code + pps
  }

  fun sameSetsAs(other: StreamDescription?): Boolean =
    other != null && vps.contentEquals(other.vps) && sps.contentEquals(other.sps) && pps.contentEquals(other.pps)

  /** Whether a decoder configured for [other] must be configured again for this one */
  fun needsNewConfiguration(other: StreamDescription?): Boolean =
    other == null || other.info.width != info.width || other.info.height != info.height ||
      other.info.codedWidth != info.codedWidth || other.info.codedHeight != info.codedHeight

  companion object {
    /** Reads three NAL units from hexadecimal text, start codes excluded; null when the SPS does not parse */
    fun fromHex(vps: String, sps: String, pps: String): StreamDescription? {
      val spsBytes = hexBytes(sps) ?: return null
      val info = HevcSpsReader.parse(spsBytes, 0, spsBytes.size) ?: return null
      return StreamDescription(hexBytes(vps) ?: return null, spsBytes, hexBytes(pps) ?: return null, info)
    }

    fun hexBytes(text: String): ByteArray? {
      val clean = text.filter { !it.isWhitespace() }
      if (clean.length % 2 != 0) {
        return null
      }
      return runCatching { ByteArray(clean.length / 2) { clean.substring(it * 2, it * 2 + 2).toInt(16).toByte() } }
        .getOrNull()
    }

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
  }
}

/**
 * Settles which codec a video channel carries, from the access units of [AccessUnitAssembler].
 *
 * 1. H.265 when a VPS, an SPS and a PPS have been read with layer 0 headers (second header byte 0x01) and the SPS
 *    gives a plausible size. The trio is the session's stream description ([description]).
 * 2. Before any parameter set, H.265 when [SIGNATURE_UNITS] units in a row open with the H.265 access unit delimiter
 *    46 01, which is how every picture of the 23 October 2026 capture opens.
 * 3. H.264 when an H.264 SPS that parses and an H.264 PPS have been seen. An H.264 stream read the H.265 way can show
 *    a type 32 (its non IDR slice header byte 0x41), but never with a second byte of 0x01 and an SPS that parses.
 *
 * Once settled, the codec stays for the stream; [reset] starts again.
 */
class CodecDetector {
  companion object {
    const val SIGNATURE_UNITS = 30
    const val DELIMITER_FIRST_BYTE = 0x46
    const val DELIMITER_SECOND_BYTE = 0x01
  }

  var codec = VideoCodec.UNKNOWN
    private set
  var evidence = CodecEvidence.NONE
    private set

  /** The last complete H.265 description read from the stream, null until one was */
  var description: StreamDescription? = null
    private set
  var h264: H264Sps? = null
    private set

  private var vps: ByteArray? = null
  private var sps: ByteArray? = null
  private var pps: ByteArray? = null
  private var h264PpsSeen = false
  private var delimiterRun = 0

  /** Reads one unit; returns a description when this unit completed a new one */
  fun offer(unit: AccessUnit): StreamDescription? {
    val header = unit.firstHeader()
    delimiterRun = if (header != null && header.first == DELIMITER_FIRST_BYTE && header.second == DELIMITER_SECOND_BYTE) {
      delimiterRun + 1
    } else {
      0
    }
    var fresh: StreamDescription? = null
    for (nal in unit.nals) {
      if (nal.size < 2) {
        continue
      }
      val first = unit.bytes[nal.offset].toInt() and 0xFF
      val second = unit.bytes[nal.offset + 1].toInt() and 0xFF
      val type = HevcNal.type(first)
      if (HevcNal.isParameterSet(type) && HevcNal.isLayerZeroHeader(first, second) &&
        second == HevcNal.LAYER_ZERO_SECOND_BYTE
      ) {
        val bytes = unit.bytes.copyOfRange(nal.offset, nal.end)
        when (type) {
          HevcNal.VPS -> vps = bytes
          HevcNal.SPS -> sps = bytes
          HevcNal.PPS -> pps = bytes
        }
        fresh = completeDescription() ?: fresh
      }
      when (H264.type(first)) {
        H264.SPS -> H264.parseSps(unit.bytes, nal.offset, nal.end)?.let { h264 = it }
        H264.PPS -> if ((first and 0x60) != 0) h264PpsSeen = true
        else -> Unit
      }
    }
    if (fresh != null) {
      codec = VideoCodec.H265
      evidence = CodecEvidence.PARAMETER_SETS
      description = fresh
      return fresh
    }
    if (codec == VideoCodec.UNKNOWN && h264 != null && h264PpsSeen) {
      codec = VideoCodec.H264
      evidence = CodecEvidence.H264_PARAMETER_SETS
    }
    if (codec == VideoCodec.UNKNOWN && delimiterRun >= SIGNATURE_UNITS) {
      codec = VideoCodec.H265
      evidence = CodecEvidence.DELIMITER_SIGNATURE
    }
    return null
  }

  /** Whether the stream shows the H.265 delimiter signature right now, parameter sets or not */
  val showsH265Signature: Boolean get() = delimiterRun >= SIGNATURE_UNITS || codec == VideoCodec.H265

  private fun completeDescription(): StreamDescription? {
    val v = vps ?: return null
    val s = sps ?: return null
    val p = pps ?: return null
    val info = HevcSpsReader.parse(s, 0, s.size) ?: return null
    val made = StreamDescription(v, s, p, info)
    return if (made.sameSetsAs(description)) null else made
  }

  fun reset() {
    codec = VideoCodec.UNKNOWN
    evidence = CodecEvidence.NONE
    description = null
    h264 = null
    vps = null
    sps = null
    pps = null
    h264PpsSeen = false
    delimiterRun = 0
  }

  /** A new stream of the same source: the description must be read again, the codec stays */
  fun newStream() {
    description = null
    vps = null
    sps = null
    pps = null
    delimiterRun = 0
  }
}
