package app.alextran.immich.djilink

/**
 * The two checksums of the control frames carried by a DJI remote controller over the USB accessory cable, written
 * from the format notes of the P2 protocol study (store/m2/dji-2026-10-21/p2/protocol.md, section 4.3), not from any
 * vendor code.
 *
 * Both are reflected CRCs with no final inversion, so running the same checksum over the bytes plus the stored
 * checksum gives zero. That is the verify form of [Crc.verify].
 *
 * The parameters live in [CrcParams] on purpose: another product family that uses the same polynomials with other
 * seeds is a new parameter set here, never a second code path.
 */
data class CrcParams(
  /** Name of the parameter set, shown on the diagnostics page */
  val label: String,
  /** Width in bits, 8 or 16 */
  val width: Int,
  /** Reflected polynomial (0x8C is the reflection of 0x31, 0x8408 the reflection of 0x1021) */
  val polynomial: Int,
  /** Initial value of the register */
  val initial: Int,
) {
  init {
    require(width == 8 || width == 16) { "unsupported CRC width $width" }
  }

  val mask: Int = (1 shl width) - 1
}

/**
 * The checksum parameters of the format notes, which are the first candidate and nothing more until real frames
 * verify with them. Another seed is one call to [header] or [frame], for a replay or a later live session.
 */
object CrcSets {
  /** Header checksum of a control frame: the first three bytes, stored at offset 3 */
  val HEADER_CRC8 = header(0x77)

  /** Frame checksum of a control frame: every byte but the last two, stored little endian in those two */
  val FRAME_CRC16 = frame(0x3692)

  fun header(seed: Int): CrcParams =
    CrcParams(label = "crc8-r8c-%02x".format(seed and 0xFF), width = 8, polynomial = 0x8C, initial = seed and 0xFF)

  fun frame(seed: Int): CrcParams = CrcParams(
    label = "crc16-r8408-%04x".format(seed and 0xFFFF),
    width = 16,
    polynomial = 0x8408,
    initial = seed and 0xFFFF,
  )
}

/**
 * A reflected CRC built once from its [params]. The table is computed at construction, so a second parameter set
 * costs one more instance and no new code.
 */
class Crc(val params: CrcParams) {
  private val table = IntArray(256) { index ->
    var value = index
    repeat(8) { value = if (value and 1 != 0) (value ushr 1) xor params.polynomial else value ushr 1 }
    value and params.mask
  }

  /** Checksum of [length] bytes of [data] from [offset] */
  fun compute(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): Int {
    require(offset >= 0 && length >= 0 && offset + length <= data.size) { "range outside the array" }
    var register = params.initial
    for (index in offset until offset + length) {
      val low = (register xor (data[index].toInt() and 0xFF)) and 0xFF
      register = (table[low] xor (register ushr 8)) and params.mask
    }
    return register
  }

  /**
   * The verify form: the checksum over the bytes and the stored checksum together, which is zero when the stored
   * value is the right one. Used rather than a comparison so that a frame is checked the way the sender built it.
   */
  fun verify(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): Boolean =
    compute(data, offset, length) == 0

  /**
   * Index of the table entry whose top byte is the given value. One step of a reflected register shifts the old
   * register right by eight bits, so the top byte of the new register is the top byte of the table entry alone, and
   * that identifies the entry. Null if two entries shared a top byte, which no CRC polynomial of these widths does.
   */
  private val byTopByte: IntArray? = run {
    val shift = params.width - 8
    val out = IntArray(256) { -1 }
    for (index in 0 until 256) {
      val top = (table[index] ushr shift) and 0xFF
      if (out[top] != -1) {
        return@run null
      }
      out[top] = index
    }
    out
  }

  /**
   * The initial value with which [verify] would accept these bytes, stored checksum included, found by running the
   * register backwards from zero. On one frame any value comes out, since every seed verifies some checksum; on many
   * real frames the same value comes out again and again, which is how a capture shows the seed of a product family
   * whose parameters differ from the notes. Null when this parameter set cannot be run backwards.
   */
  fun seedFor(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): Int? {
    require(offset >= 0 && length >= 0 && offset + length <= data.size) { "range outside the array" }
    val reverse = byTopByte ?: return null
    val shift = params.width - 8
    var register = 0
    for (index in offset + length - 1 downTo offset) {
      val entry = reverse[(register ushr shift) and 0xFF]
      val shiftedOut = (register xor table[entry]) and 0xFF
      val low = (entry xor (data[index].toInt() and 0xFF)) and 0xFF
      register = ((shiftedOut shl 8) or low) and params.mask
    }
    return register
  }
}

/**
 * Votes for checksum seeds, bounded: at most [maxValues] distinct values are kept and every vote beyond them is
 * counted in [others]. The value with the most votes is the candidate a page or a header shows.
 */
class SeedTally(private val maxValues: Int = 64) {
  private val votes = linkedMapOf<Int, Long>()

  var total = 0L
    private set
  var others = 0L
    private set

  fun vote(seed: Int?) {
    if (seed == null) {
      return
    }
    total += 1
    val current = votes[seed]
    when {
      current != null -> votes[seed] = current + 1
      votes.size < maxValues -> votes[seed] = 1
      else -> others += 1
    }
  }

  /** The most voted value and its votes, null while nothing voted */
  fun top(): Pair<Int, Long>? = votes.maxByOrNull { it.value }?.let { it.key to it.value }

  fun add(other: SeedTally) {
    for ((seed, count) in other.votes) {
      val current = votes[seed]
      when {
        current != null -> votes[seed] = current + count
        votes.size < maxValues -> votes[seed] = count
        else -> others += count
      }
      total += count
    }
    others += other.others
    total += other.others
  }

  fun clear() {
    votes.clear()
    total = 0
    others = 0
  }
}
