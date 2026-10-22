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

/** The checksum parameters compiled into the controller application this format was read from. */
object CrcSets {
  /** Header checksum of a control frame: the first three bytes, stored at offset 3 */
  val HEADER_CRC8 = CrcParams(label = "crc8-r8c-77", width = 8, polynomial = 0x8C, initial = 0x77)

  /** Frame checksum of a control frame: every byte but the last two, stored little endian in those two */
  val FRAME_CRC16 = CrcParams(label = "crc16-r8408-3692", width = 16, polynomial = 0x8408, initial = 0x3692)
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
}
