package app.alextran.immich.djilink

/**
 * The eight byte envelope that carries every control and video unit on the accessory stream, written from the format
 * notes of the P2 protocol study (p2/protocol.md, section 3): two sync bytes 0x55 0xCC, the channel as an unsigned 16
 * bit little endian value, the payload length as an unsigned 32 bit little endian value, then the payload. There is no
 * checksum at this level.
 *
 * [EnvelopeDecoder] is a streaming decoder: it keeps the leftover bytes between reads, returns every frame a read
 * completes, and never looks for the sync pattern inside a payload whose length it already trusts. It validates the
 * length against [MAX_PAYLOAD] before it trusts a header, bounds how long it waits for an incomplete frame, and counts
 * everything it throws away, because on this hardware a counter is the only evidence available.
 */
data class EnvelopeFrame(val channel: Int, val payload: ByteArray) {
  override fun equals(other: Any?): Boolean =
    other is EnvelopeFrame && other.channel == channel && other.payload.contentEquals(payload)

  override fun hashCode(): Int = 31 * channel + payload.contentHashCode()
}

data class EnvelopeCounters(
  val frames: Long = 0,
  val frameBytes: Long = 0,
  val payloadBytes: Long = 0,
  val discardedBytes: Long = 0,
  val resynchronisations: Long = 0,
  val unknownChannelFrames: Long = 0,
  val oversizeRejections: Long = 0,
  val incompleteTimeouts: Long = 0,
)

class EnvelopeDecoder(
  private val maxPayload: Int = MAX_PAYLOAD,
  private val incompleteTimeoutMs: Long = INCOMPLETE_TIMEOUT_MS,
  private val clockMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
  companion object {
    const val SYNC_FIRST = 0x55
    const val SYNC_SECOND = 0xCC
    const val HEADER_SIZE = 8

    /** Length above which a header is noise, from the notes of section 3 */
    const val MAX_PAYLOAD = 2_097_152

    /**
     * How long a plausible but incomplete frame is waited for. The controller application has no policy here, it only
     * grows its buffer; a bounded wait is ours, so that one bad length cannot stall the stream for ever.
     */
    const val INCOMPLETE_TIMEOUT_MS = 2_000L

    /** Encodes one frame; used by the replay tests and by any later stage that sends */
    fun encode(channel: Int, payload: ByteArray): ByteArray {
      require(channel in 0..0xFFFF) { "channel outside 16 bits" }
      val out = ByteArray(HEADER_SIZE + payload.size)
      out[0] = SYNC_FIRST.toByte()
      out[1] = SYNC_SECOND.toByte()
      out[2] = (channel and 0xFF).toByte()
      out[3] = ((channel ushr 8) and 0xFF).toByte()
      val length = payload.size
      out[4] = (length and 0xFF).toByte()
      out[5] = ((length ushr 8) and 0xFF).toByte()
      out[6] = ((length ushr 16) and 0xFF).toByte()
      out[7] = ((length ushr 24) and 0xFF).toByte()
      payload.copyInto(out, HEADER_SIZE)
      return out
    }
  }

  private var buffer = ByteArray(16 * 1024)
  private var head = 0
  private var tail = 0

  /** When the first wait for the frame being assembled started, null while nothing is pending */
  private var pendingSince: Long? = null

  /** True while bytes are being thrown away looking for a sync pattern, so that one run counts as one resynchronisation */
  private var resynchronising = false

  var counters = EnvelopeCounters()
    private set

  val buffered: Int get() = tail - head

  /** Bytes offered, then every frame they complete. A read of zero bytes only drives the incomplete frame timeout. */
  fun offer(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): List<EnvelopeFrame> {
    require(offset >= 0 && length >= 0 && offset + length <= data.size) { "range outside the array" }
    if (length > 0) {
      ensureRoom(length)
      data.copyInto(buffer, tail, offset, offset + length)
      tail += length
    }
    return drain()
  }

  /** Frames the buffered bytes already complete, and the incomplete frame timeout when nothing arrives */
  fun pump(): List<EnvelopeFrame> = drain()

  /** The buffer is never kept across a reconnect: a new descriptor starts a new stream */
  fun reset() {
    head = 0
    tail = 0
    pendingSince = null
    resynchronising = false
  }

  private fun drain(): List<EnvelopeFrame> {
    val frames = mutableListOf<EnvelopeFrame>()
    while (true) {
      val available = tail - head
      if (available < 2) {
        break
      }
      if ((buffer[head].toInt() and 0xFF) != SYNC_FIRST || (buffer[head + 1].toInt() and 0xFF) != SYNC_SECOND) {
        skipOneByte()
        continue
      }
      if (available < HEADER_SIZE) {
        if (waitedTooLong()) {
          continue
        }
        break
      }
      val channel = u16(head + 2)
      val payloadLength = u32(head + 4)
      if (payloadLength > maxPayload) {
        counters = counters.copy(oversizeRejections = counters.oversizeRejections + 1)
        skipOneByte()
        continue
      }
      val total = HEADER_SIZE + payloadLength.toInt()
      if (available < total) {
        if (waitedTooLong()) {
          continue
        }
        break
      }
      val payload = buffer.copyOfRange(head + HEADER_SIZE, head + total)
      head += total
      pendingSince = null
      resynchronising = false
      counters = counters.copy(
        frames = counters.frames + 1,
        frameBytes = counters.frameBytes + total,
        payloadBytes = counters.payloadBytes + payload.size,
        unknownChannelFrames =
          counters.unknownChannelFrames + if (Channels.isKnown(channel)) 0 else 1,
      )
      frames.add(EnvelopeFrame(channel, payload))
    }
    compact()
    return frames
  }

  /** True when the frame being waited for has been pending longer than the bound, which also skips one byte */
  private fun waitedTooLong(): Boolean {
    val now = clockMs()
    val since = pendingSince
    if (since == null) {
      pendingSince = now
      return false
    }
    if (now - since < incompleteTimeoutMs) {
      return false
    }
    counters = counters.copy(incompleteTimeouts = counters.incompleteTimeouts + 1)
    pendingSince = null
    skipOneByte()
    return true
  }

  private fun skipOneByte() {
    head += 1
    counters = counters.copy(
      discardedBytes = counters.discardedBytes + 1,
      resynchronisations = counters.resynchronisations + if (resynchronising) 0 else 1,
    )
    resynchronising = true
    pendingSince = null
  }

  private fun u16(at: Int): Int = (buffer[at].toInt() and 0xFF) or ((buffer[at + 1].toInt() and 0xFF) shl 8)

  private fun u32(at: Int): Long =
    (buffer[at].toLong() and 0xFF) or
      ((buffer[at + 1].toLong() and 0xFF) shl 8) or
      ((buffer[at + 2].toLong() and 0xFF) shl 16) or
      ((buffer[at + 3].toLong() and 0xFF) shl 24)

  private fun compact() {
    if (head == 0) {
      return
    }
    if (head == tail) {
      head = 0
      tail = 0
      return
    }
    if (head >= buffer.size / 2) {
      buffer.copyInto(buffer, 0, head, tail)
      tail -= head
      head = 0
    }
  }

  private fun ensureRoom(length: Int) {
    if (tail + length <= buffer.size) {
      return
    }
    if (head > 0) {
      buffer.copyInto(buffer, 0, head, tail)
      tail -= head
      head = 0
      if (tail + length <= buffer.size) {
        return
      }
    }
    // Bounded: a frame can never be larger than the header plus the ceiling, plus one read
    val cap = HEADER_SIZE + maxPayload + AoaTransport.READ_SIZE
    var size = buffer.size
    while (size < tail + length && size < cap) {
      size = minOf(cap, size * 2)
    }
    if (size < tail + length) {
      // More bytes than any frame could need: the oldest ones cannot belong to a frame we will complete
      val keep = cap - length
      buffer.copyInto(buffer, 0, tail - keep, tail)
      counters = counters.copy(discardedBytes = counters.discardedBytes + (tail - keep))
      tail = keep
      head = 0
      size = cap
    }
    if (size != buffer.size) {
      buffer = buffer.copyOf(size)
    }
  }
}
