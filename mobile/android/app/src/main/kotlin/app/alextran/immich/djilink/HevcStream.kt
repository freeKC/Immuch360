package app.alextran.immich.djilink

/**
 * Our own reader of the few parts of an H.265 elementary stream this link needs, written from the ITU-T H.265
 * specification: the Annex B start code (B.2), the two byte NAL unit header (7.3.1.2), the removal of the emulation
 * prevention bytes (7.4.2), an Exp-Golomb bit reader (9.2), the start of the sequence parameter set up to the bit
 * depths (7.3.2.2 with profile_tier_level of 7.3.3), and the headers of the SEI messages (7.3.5). Nothing more of the
 * stream is read here: the platform decoder reads the rest itself.
 *
 * The codec of the 23 October 2026 capture (p2/capture-2026-10-23.md, section 4) is H.265 Main, 1920 x 1080, so that
 * is the codec decoded in this stage. H.264 is recognised by its own sequence parameter set ([H264]) and reported, not
 * decoded: no H.264 product has been captured.
 */
object HevcNal {
  const val VPS = 32
  const val SPS = 33
  const val PPS = 34
  const val ACCESS_UNIT_DELIMITER = 35
  const val END_OF_SEQUENCE = 36
  const val END_OF_BITSTREAM = 37
  const val FILLER = 38
  const val PREFIX_SEI = 39
  const val SUFFIX_SEI = 40

  /** The second header byte of a layer 0 NAL unit with temporal id 0 (nuh_temporal_id_plus1 = 1) */
  const val LAYER_ZERO_SECOND_BYTE = 0x01

  fun type(firstHeaderByte: Int): Int = (firstHeaderByte shr 1) and 0x3F

  /** A slice segment of a picture: the VCL types 0 to 31 */
  fun isSlice(type: Int): Boolean = type in 0..31

  /** An intra random access point picture (BLA, IDR, CRA): types 16 to 21 */
  fun isIntraRandomAccess(type: Int): Boolean = type in 16..21

  fun isParameterSet(type: Int): Boolean = type == VPS || type == SPS || type == PPS

  /**
   * Whether two header bytes are a well formed layer 0 header: forbidden_zero_bit clear, nuh_layer_id 0 and
   * nuh_temporal_id_plus1 not zero. A parameter set of this stream also has a temporal id of 0, so its second byte is
   * exactly [LAYER_ZERO_SECOND_BYTE].
   */
  fun isLayerZeroHeader(first: Int, second: Int): Boolean =
    (first and 0x80) == 0 && (first and 0x01) == 0 && (second and 0xF8) == 0 && (second and 0x07) != 0
}

/** Where one NAL unit sits in a buffer: [offset] is its first header byte, [end] is exclusive */
data class NalRef(val offset: Int, val end: Int) {
  val size: Int get() = end - offset
}

object AnnexB {
  /** True at [index] when the three bytes there are the start code prefix 00 00 01 */
  fun isStartCodeAt(bytes: ByteArray, index: Int, end: Int = bytes.size): Boolean =
    index + 2 < end && bytes[index].toInt() == 0 && bytes[index + 1].toInt() == 0 && bytes[index + 2].toInt() == 1

  /**
   * Every NAL unit of an Annex B buffer between [from] and [to], start codes excluded and the zero bytes that precede
   * the next start code (its leading zero_byte, or trailing_zero_8bits) trimmed off the end of each unit.
   */
  fun split(bytes: ByteArray, from: Int = 0, to: Int = bytes.size): List<NalRef> {
    val starts = mutableListOf<Int>()
    var index = from
    while (index + 2 < to) {
      if (isStartCodeAt(bytes, index, to)) {
        starts.add(index + 3)
        index += 3
      } else {
        index += 1
      }
    }
    val units = ArrayList<NalRef>(starts.size)
    for ((position, start) in starts.withIndex()) {
      var end = if (position + 1 < starts.size) starts[position + 1] - 3 else to
      while (end > start && bytes[end - 1].toInt() == 0 && position + 1 < starts.size) {
        end -= 1
      }
      if (end > start) {
        units.add(NalRef(start, end))
      }
    }
    return units
  }

  /** The NAL unit payload with its emulation prevention bytes (00 00 03) removed, from [from] to [to] */
  fun unescape(bytes: ByteArray, from: Int, to: Int): ByteArray {
    val out = ByteArray(to - from)
    var size = 0
    var zeros = 0
    for (index in from until to) {
      val value = bytes[index].toInt() and 0xFF
      if (zeros >= 2 && value == 0x03) {
        zeros = 0
        continue
      }
      out[size++] = value.toByte()
      zeros = if (value == 0) zeros + 1 else 0
    }
    return if (size == out.size) out else out.copyOf(size)
  }
}

/** Reads bits most significant first, with the unsigned and signed Exp-Golomb codes of the specification */
class BitReader(private val data: ByteArray, private val from: Int = 0, private val to: Int = data.size) {
  private var position = from.toLong() * 8

  val bitsLeft: Long get() = to.toLong() * 8 - position

  fun bit(): Int {
    if (position >= to.toLong() * 8) {
      throw IndexOutOfBoundsException("read past the end of the unit")
    }
    val byte = data[(position ushr 3).toInt()].toInt() and 0xFF
    val bit = (byte shr (7 - (position and 7).toInt())) and 1
    position += 1
    return bit
  }

  /** Up to 32 bits as an unsigned value in a Long */
  fun bits(count: Int): Long {
    require(count in 0..32) { "at most 32 bits at a time" }
    var value = 0L
    repeat(count) { value = (value shl 1) or bit().toLong() }
    return value
  }

  fun flag(): Boolean = bit() == 1

  fun skip(count: Long) {
    if (count > bitsLeft) {
      throw IndexOutOfBoundsException("skipped past the end of the unit")
    }
    position += count
  }

  /** ue(v); refuses a code longer than 31 leading zeros, which no field read here can have */
  fun ue(): Long {
    var zeros = 0
    while (bit() == 0) {
      zeros += 1
      if (zeros > 31) {
        throw IllegalStateException("an Exp-Golomb code longer than 32 bits")
      }
    }
    return (1L shl zeros) - 1 + bits(zeros)
  }

  fun se(): Long {
    val code = ue()
    return if (code % 2 == 1L) (code + 1) / 2 else -(code / 2)
  }
}

/** The fields of an H.265 sequence parameter set that this link shows and configures a decoder with */
data class HevcSps(
  val vpsId: Int,
  val maxSubLayersMinus1: Int,
  val profileSpace: Int,
  val highTier: Boolean,
  val profileIdc: Int,
  val compatibilityFlags: Long,
  val levelIdc: Int,
  val spsId: Int,
  val chromaFormatIdc: Int,
  val codedWidth: Int,
  val codedHeight: Int,
  val confWindowLeft: Int,
  val confWindowRight: Int,
  val confWindowTop: Int,
  val confWindowBottom: Int,
  val bitDepthLuma: Int,
  val bitDepthChroma: Int,
) {
  private val subWidth: Int get() = if (chromaFormatIdc == 1 || chromaFormatIdc == 2) 2 else 1
  private val subHeight: Int get() = if (chromaFormatIdc == 1) 2 else 1

  /** The size after the conformance window, which is what a viewer sees */
  val width: Int get() = codedWidth - subWidth * (confWindowLeft + confWindowRight)
  val height: Int get() = codedHeight - subHeight * (confWindowTop + confWindowBottom)

  val conformanceWindowZero: Boolean
    get() = confWindowLeft == 0 && confWindowRight == 0 && confWindowTop == 0 && confWindowBottom == 0

  /** A size and a format a decoder can be configured with; anything else is a parse of something that is not an SPS */
  val plausible: Boolean
    get() = codedWidth in 16..8192 &&
      codedHeight in 16..8192 &&
      width > 0 &&
      height > 0 &&
      chromaFormatIdc in 0..3 &&
      bitDepthLuma in 8..16 &&
      bitDepthChroma in 8..16 &&
      levelIdc in 1..255

  /** The general profile, as the specification numbers it: 1 Main, 2 Main 10, 3 Main Still Picture, 4 range extensions */
  val profileName: String
    get() = when (profileIdc) {
      1 -> "Main"
      2 -> "Main 10"
      3 -> "Main Still Picture"
      4 -> "Range extensions"
      else -> "profile $profileIdc"
    }

  /** general_level_idc is thirty times the level number: 150 is level 5, 153 level 5.1 */
  val levelName: String
    get() {
      val major = levelIdc / 30
      val minor = (levelIdc % 30) / 3
      return "$major.$minor"
    }
}

object HevcSpsReader {
  /**
   * Reads the SPS whose NAL unit header starts at [offset] and ends at [end]. Null for anything that is not an SPS or
   * that ends before its bit depths, never an exception: a truncated unit is a fact of a radio link.
   */
  fun parse(bytes: ByteArray, offset: Int, end: Int): HevcSps? {
    if (end - offset < 4) {
      return null
    }
    val first = bytes[offset].toInt() and 0xFF
    val second = bytes[offset + 1].toInt() and 0xFF
    if (HevcNal.type(first) != HevcNal.SPS || !HevcNal.isLayerZeroHeader(first, second)) {
      return null
    }
    val rbsp = AnnexB.unescape(bytes, offset + 2, end)
    return runCatching { read(BitReader(rbsp)) }.getOrNull()?.takeIf { it.plausible }
  }

  private fun read(reader: BitReader): HevcSps {
    val vpsId = reader.bits(4).toInt()
    val maxSubLayersMinus1 = reader.bits(3).toInt()
    reader.skip(1) // sps_temporal_id_nesting_flag
    // profile_tier_level(1, sps_max_sub_layers_minus1)
    val profileSpace = reader.bits(2).toInt()
    val highTier = reader.flag()
    val profileIdc = reader.bits(5).toInt()
    val compatibility = reader.bits(32)
    // progressive, interlaced, non packed and frame only flags, then 43 bits of constraint flags and one more bit
    reader.skip(4 + 43 + 1)
    val levelIdc = reader.bits(8).toInt()
    val subLayerProfilePresent = BooleanArray(maxSubLayersMinus1)
    val subLayerLevelPresent = BooleanArray(maxSubLayersMinus1)
    for (layer in 0 until maxSubLayersMinus1) {
      subLayerProfilePresent[layer] = reader.flag()
      subLayerLevelPresent[layer] = reader.flag()
    }
    if (maxSubLayersMinus1 > 0) {
      reader.skip(2L * (8 - maxSubLayersMinus1)) // reserved_zero_2bits
    }
    for (layer in 0 until maxSubLayersMinus1) {
      if (subLayerProfilePresent[layer]) {
        reader.skip(88)
      }
      if (subLayerLevelPresent[layer]) {
        reader.skip(8)
      }
    }
    val spsId = reader.ue().toInt()
    val chroma = reader.ue().toInt()
    if (chroma == 3) {
      reader.skip(1) // separate_colour_plane_flag
    }
    val width = reader.ue().toInt()
    val height = reader.ue().toInt()
    var left = 0
    var right = 0
    var top = 0
    var bottom = 0
    if (reader.flag()) {
      left = reader.ue().toInt()
      right = reader.ue().toInt()
      top = reader.ue().toInt()
      bottom = reader.ue().toInt()
    }
    val luma = reader.ue().toInt() + 8
    val chromaDepth = reader.ue().toInt() + 8
    return HevcSps(
      vpsId = vpsId,
      maxSubLayersMinus1 = maxSubLayersMinus1,
      profileSpace = profileSpace,
      highTier = highTier,
      profileIdc = profileIdc,
      compatibilityFlags = compatibility,
      levelIdc = levelIdc,
      spsId = spsId,
      chromaFormatIdc = chroma,
      codedWidth = width,
      codedHeight = height,
      confWindowLeft = left,
      confWindowRight = right,
      confWindowTop = top,
      confWindowBottom = bottom,
      bitDepthLuma = luma,
      bitDepthChroma = chromaDepth,
    )
  }
}

/** One SEI message: its payload type and size, and where its payload sits in the unescaped [rbsp] */
class SeiMessage(val payloadType: Int, val payloadSize: Int, val payloadOffset: Int, val rbsp: ByteArray) {
  fun payloadByte(index: Int): Int = rbsp[payloadOffset + index].toInt() and 0xFF
}

object SeiReader {
  /**
   * The messages of the SEI NAL unit whose header starts at [offset]: payload type and size each as a run of 0xFF
   * bytes plus a last byte (7.3.5), until the RBSP trailing bits. A message that claims more bytes than the unit holds
   * ends the list.
   */
  fun messages(bytes: ByteArray, offset: Int, end: Int): List<SeiMessage> {
    if (end - offset < 3) {
      return emptyList()
    }
    val rbsp = AnnexB.unescape(bytes, offset + 2, end)
    val out = mutableListOf<SeiMessage>()
    var index = 0
    while (index < rbsp.size) {
      // The RBSP trailing bits: a lone 0x80 is the end of the unit, not a message
      if (index == rbsp.size - 1 && (rbsp[index].toInt() and 0xFF) == 0x80) {
        break
      }
      var type = 0
      while (index < rbsp.size && (rbsp[index].toInt() and 0xFF) == 0xFF) {
        type += 255
        index += 1
      }
      if (index >= rbsp.size) {
        break
      }
      type += rbsp[index].toInt() and 0xFF
      index += 1
      var size = 0
      while (index < rbsp.size && (rbsp[index].toInt() and 0xFF) == 0xFF) {
        size += 255
        index += 1
      }
      if (index >= rbsp.size) {
        break
      }
      size += rbsp[index].toInt() and 0xFF
      index += 1
      if (index + size > rbsp.size) {
        break
      }
      out.add(SeiMessage(type, size, index, rbsp))
      index += size
    }
    return out
  }
}

/**
 * The picture counter the remote puts in the suffix SEI of every picture: the first two bytes, little endian, of the
 * SEI message of payload type 240. Seen on the 23 October 2026 capture only (p2/capture-2026-10-23.md, section 4.4):
 * +1 at every picture, back to 1 when the encoder restarts. No public source describes the message, so it is named
 * here by what it does and used as a loss detector, nothing more.
 */
object SeiPictureCounter {
  const val PAYLOAD_TYPE = 240

  /** The counter of the unit, from its first suffix SEI that carries one */
  fun read(bytes: ByteArray, nals: List<NalRef>): Int? {
    for (nal in nals) {
      if (nal.size < 3 || HevcNal.type(bytes[nal.offset].toInt() and 0xFF) != HevcNal.SUFFIX_SEI) {
        continue
      }
      for (message in SeiReader.messages(bytes, nal.offset, nal.end)) {
        if (message.payloadType == PAYLOAD_TYPE && message.payloadSize >= 2) {
          return message.payloadByte(0) or (message.payloadByte(1) shl 8)
        }
      }
    }
    return null
  }
}

/**
 * Lost pictures and encoder restarts from the SEI picture counter: a step of +1 is the next picture, a step of +k with
 * k from 2 to [MAX_LOSS_STEP] counts k minus 1 pictures lost on the radio link, and any other step (the capture shows
 * 2275 to 1 when the encoder restarted at the landing) counts a restart and no loss. The counter is 16 bits, so a step
 * is taken modulo 65536.
 */
class PictureCounterTracker {
  companion object {
    const val MAX_LOSS_STEP = 300
  }

  var counters = 0L
    private set
  var steps = 0L
    private set
  var lost = 0L
    private set
  var restarts = 0L
    private set
  var last: Int? = null
    private set

  fun offer(value: Int) {
    counters += 1
    val previous = last
    last = value
    if (previous == null) {
      return
    }
    val step = (value - previous + 65536) % 65536
    when (step) {
      1 -> steps += 1
      in 2..MAX_LOSS_STEP -> lost += step - 1
      else -> restarts += 1
    }
  }

  /** A new stream: the next counter is a first one again, the totals stay */
  fun newStream() {
    last = null
  }

  fun reset() {
    counters = 0
    steps = 0
    lost = 0
    restarts = 0
    last = null
  }
}

/** The fields of an H.264 sequence parameter set that tell an H.264 stream from anything else (7.3.2.1.1 of H.264) */
data class H264Sps(val profileIdc: Int, val levelIdc: Int, val spsId: Int, val chromaFormatIdc: Int)

object H264 {
  const val SPS = 7
  const val PPS = 8

  /** nal_unit_type of the one byte H.264 header, when its forbidden bit is clear */
  fun type(headerByte: Int): Int? = if ((headerByte and 0x80) == 0) headerByte and 0x1F else null

  private val highProfiles = setOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)
  private val knownProfiles = setOf(66, 77, 88) + highProfiles

  /** Reads an H.264 SPS whose header byte is at [offset]; null for anything that does not parse as one */
  fun parseSps(bytes: ByteArray, offset: Int, end: Int): H264Sps? {
    if (end - offset < 5) {
      return null
    }
    val header = bytes[offset].toInt() and 0xFF
    if (type(header) != SPS || (header and 0x60) == 0) {
      return null
    }
    val rbsp = AnnexB.unescape(bytes, offset + 1, end)
    return runCatching {
      val reader = BitReader(rbsp)
      val profile = reader.bits(8).toInt()
      reader.skip(8) // constraint flags and reserved bits
      val level = reader.bits(8).toInt()
      val spsId = reader.ue().toInt()
      var chroma = 1
      if (profile in highProfiles) {
        chroma = reader.ue().toInt()
        if (chroma == 3) {
          reader.skip(1)
        }
        val lumaDepth = reader.ue().toInt()
        val chromaDepth = reader.ue().toInt()
        if (lumaDepth > 6 || chromaDepth > 6) {
          return@runCatching null
        }
      }
      if (profile !in knownProfiles || spsId > 31 || chroma > 3 || level !in 9..62) {
        null
      } else {
        H264Sps(profile, level, spsId, chroma)
      }
    }.getOrNull()
  }
}
