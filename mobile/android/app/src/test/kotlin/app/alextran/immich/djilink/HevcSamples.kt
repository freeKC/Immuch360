package app.alextran.immich.djilink

/**
 * Small H.265 NAL units built by the tests, after the NAL unit header of H.265 section 7.3.1.2, and the 102 byte stream
 * description of the 23 October 2026 capture that the RC-N3 and Neo 2 profile carries.
 */
object HevcSamples {
  val START = byteArrayOf(0, 0, 0, 1)

  /** The access unit delimiter the remote puts at the end of a picture's last fragment: 46 01, pic_type 1 */
  val DELIMITER = byteArrayOf(0x46, 0x01, 0x30)

  fun hex(text: String): ByteArray = StreamDescription.hexBytes(text)!!

  val VPS = hex(ProfileRegistry.SEED_VPS_20261023)
  val SPS = hex(ProfileRegistry.SEED_SPS_20261023)
  val PPS = hex(ProfileRegistry.SEED_PPS_20261023)

  /** A slice of type [type] (1 is a trailing picture, 19 and 20 are IDR pictures), [body] bytes of filler after */
  fun slice(type: Int = 1, first: Boolean = true, body: Int = 40, fill: Int = 0x5A): ByteArray {
    val header = byteArrayOf(((type shl 1) and 0x7E).toByte(), 0x01)
    val firstByte = (if (first) 0x80 else 0x00) or 0x2F
    return header + byteArrayOf(firstByte.toByte()) + ByteArray(body) { fill.toByte() }
  }

  /** A suffix SEI holding the picture counter of payload type 240, then a message of payload type 256 */
  fun suffixSei(counter: Int): ByteArray = byteArrayOf(
    0x50,
    0x01,
    0xF0.toByte(),
    0x02,
    (counter and 0xFF).toByte(),
    ((counter shr 8) and 0xFF).toByte(),
    0xFF.toByte(),
    0x01,
    0x01,
    0x33,
    0x80.toByte(),
  )

  /**
   * A suffix SEI with the 25 byte message of payload type 240 as the 25 October 2026 capture has it (its first picture),
   * with [counter] at bytes 0 and 1 and the millisecond content clock [clockMs] at bytes 15 and 16
   */
  fun suffixSeiWithClock(counter: Int, clockMs: Int): ByteArray {
    val payload = hex("01003c00ce01400053cb27ff20009ff627f00000c0008f9780")
    payload[0] = (counter and 0xFF).toByte()
    payload[1] = ((counter shr 8) and 0xFF).toByte()
    payload[15] = (clockMs and 0xFF).toByte()
    payload[16] = ((clockMs shr 8) and 0xFF).toByte()
    return byteArrayOf(0x50, 0x01, 0xF0.toByte(), payload.size.toByte()) + payload + byteArrayOf(0x80.toByte())
  }

  fun annexB(vararg nals: ByteArray): ByteArray = nals.fold(ByteArray(0)) { all, nal -> all + START + nal }

  /** An access unit made by hand, typed the H.265 way, without the assembler */
  fun unitOf(vararg nals: ByteArray, arrivalNs: Long = 0, channel: Int = 22346): AccessUnit {
    val bytes = annexB(*nals)
    val offsets = mutableListOf<Int>()
    var at = 0
    for (nal in nals) {
      at += START.size
      offsets.add(at)
      at += nal.size
    }
    return AccessUnit(
      bytes = bytes,
      nalTypes = offsets.map { HevcNal.type(bytes[it].toInt() and 0xFF) }.toIntArray(),
      nalOffsets = offsets.toIntArray(),
      firstArrivalNs = arrivalNs,
      lastArrivalNs = arrivalNs,
      closedBy = AccessUnitClose.BOUNDARY,
      channel = channel,
    )
  }

  /** One picture as the remote sends it: delimiter, slice, suffix SEI */
  fun picture(counter: Int, type: Int = 1, body: Int = 40): ByteArray =
    annexB(DELIMITER, slice(type, body = body), suffixSei(counter))
}
