package app.alextran.immich.djilink

/**
 * The control frame carried inside a control channel envelope, written from the format notes of the P2 protocol study
 * (p2/protocol.md, section 4): magic 0x55, a 16 bit field whose low ten bits are the total length and whose upper six
 * bits are the version, the header checksum at offset 3, sender and receiver each packed as a device type and an index,
 * a 16 bit sequence, a byte carrying the kind, the acknowledgement policy and the encryption type, the command set,
 * the command id, the body, and the frame checksum little endian in the last two bytes.
 *
 * A frame whose encryption field is not zero is counted as unsupported and its body is never interpreted: guessing at
 * a cipher would put invented numbers in front of a pilot.
 */
data class P3Frame(
  val version: Int,
  val senderType: Int,
  val senderIndex: Int,
  val receiverType: Int,
  val receiverIndex: Int,
  val sequence: Int,
  /** False for a request, true for an acknowledgement */
  val isAcknowledgement: Boolean,
  /** 0 none, 1 push, 2 required */
  val ackPolicy: Int,
  /** 0 none; anything else is unsupported here */
  val encryption: Int,
  val commandSet: Int,
  val commandId: Int,
  val body: ByteArray,
) {
  val encryptionUnsupported: Boolean get() = encryption != 0

  override fun equals(other: Any?): Boolean =
    other is P3Frame &&
      other.version == version &&
      other.senderType == senderType &&
      other.senderIndex == senderIndex &&
      other.receiverType == receiverType &&
      other.receiverIndex == receiverIndex &&
      other.sequence == sequence &&
      other.isAcknowledgement == isAcknowledgement &&
      other.ackPolicy == ackPolicy &&
      other.encryption == encryption &&
      other.commandSet == commandSet &&
      other.commandId == commandId &&
      other.body.contentEquals(body)

  override fun hashCode(): Int {
    var result = version
    result = 31 * result + senderType
    result = 31 * result + senderIndex
    result = 31 * result + receiverType
    result = 31 * result + receiverIndex
    result = 31 * result + sequence
    result = 31 * result + if (isAcknowledgement) 1 else 0
    result = 31 * result + ackPolicy
    result = 31 * result + encryption
    result = 31 * result + commandSet
    result = 31 * result + commandId
    result = 31 * result + body.contentHashCode()
    return result
  }
}

/** Device types of the header that this work needs to name; the others stay numbers on the page */
object DeviceTypes {
  const val CAMERA = 1
  const val APPLICATION = 2
  const val FLIGHT_CONTROLLER = 3
  const val GIMBAL = 4
  const val CENTRE_BOARD = 5
  const val REMOTE_CONTROLLER = 6
  const val OFDM_RADIO = 9
  const val BATTERY = 11
  const val GLASSES = 28
  const val BROADCAST = 31
}

/** Command sets this work names; an unnamed set is shown as its number and counted */
object CommandSets {
  const val COMMON = 0
  const val SPECIAL = 1
  const val CAMERA = 2
  const val FLIGHT_CONTROLLER = 3
  const val GIMBAL = 4
  const val REMOTE_CONTROLLER = 6
  const val OSD = 9
  const val BATTERY = 12
  const val SMART_BATTERY = 13
}

data class P3Counters(
  val frames: Long = 0,
  val frameBytes: Long = 0,
  val headerCrcFailures: Long = 0,
  val frameCrcFailures: Long = 0,
  val lengthRejections: Long = 0,
  val discardedBytes: Long = 0,
  val resynchronisations: Long = 0,
  val unsupportedEncryption: Long = 0,
)

/**
 * A streaming decoder for control frames. One decoder per control channel: the bytes of one channel are one stream,
 * and a frame can straddle two envelopes.
 */
class P3Decoder {
  companion object {
    const val MAGIC = 0x55
    const val MIN_SIZE = 13

    /** The length field is ten bits wide */
    const val MAX_SIZE = 1023
    const val DEFAULT_VERSION = 1

    private val headerCrc = Crc(CrcSets.HEADER_CRC8)
    private val frameCrc = Crc(CrcSets.FRAME_CRC16)

    /**
     * Builds a frame with both checksums in place. Nothing in stage 1 sends one; the builder exists so that the
     * decoder is tested against frames built to the same description, and so that a later stage has one place where
     * the wire format lives.
     */
    fun build(
      senderType: Int,
      senderIndex: Int = 0,
      receiverType: Int,
      receiverIndex: Int = 0,
      sequence: Int,
      isAcknowledgement: Boolean = false,
      ackPolicy: Int = 0,
      encryption: Int = 0,
      commandSet: Int,
      commandId: Int,
      body: ByteArray = ByteArray(0),
      version: Int = DEFAULT_VERSION,
    ): ByteArray {
      val total = MIN_SIZE + body.size
      require(total <= MAX_SIZE) { "frame of $total bytes above the ten bit length" }
      require(version in 0..63) { "version outside six bits" }
      val out = ByteArray(total)
      out[0] = MAGIC.toByte()
      val lengthAndVersion = (total and 0x3FF) or ((version and 0x3F) shl 10)
      out[1] = (lengthAndVersion and 0xFF).toByte()
      out[2] = ((lengthAndVersion ushr 8) and 0xFF).toByte()
      out[3] = headerCrc.compute(out, 0, 3).toByte()
      out[4] = (((senderIndex and 0x07) shl 5) or (senderType and 0x1F)).toByte()
      out[5] = (((receiverIndex and 0x07) shl 5) or (receiverType and 0x1F)).toByte()
      out[6] = (sequence and 0xFF).toByte()
      out[7] = ((sequence ushr 8) and 0xFF).toByte()
      out[8] = (
        (if (isAcknowledgement) 0x80 else 0) or
          ((ackPolicy and 0x03) shl 5) or
          (encryption and 0x07)
        ).toByte()
      out[9] = (commandSet and 0xFF).toByte()
      out[10] = (commandId and 0xFF).toByte()
      body.copyInto(out, 11)
      val crc = frameCrc.compute(out, 0, total - 2)
      out[total - 2] = (crc and 0xFF).toByte()
      out[total - 1] = ((crc ushr 8) and 0xFF).toByte()
      return out
    }

    /** Reads a complete frame with both checksums already verified by the caller */
    fun parse(data: ByteArray, offset: Int, total: Int): P3Frame {
      val lengthAndVersion = (data[offset + 1].toInt() and 0xFF) or ((data[offset + 2].toInt() and 0xFF) shl 8)
      val sender = data[offset + 4].toInt() and 0xFF
      val receiver = data[offset + 5].toInt() and 0xFF
      val control = data[offset + 8].toInt() and 0xFF
      return P3Frame(
        version = (lengthAndVersion ushr 10) and 0x3F,
        senderType = sender and 0x1F,
        senderIndex = (sender ushr 5) and 0x07,
        receiverType = receiver and 0x1F,
        receiverIndex = (receiver ushr 5) and 0x07,
        sequence = (data[offset + 6].toInt() and 0xFF) or ((data[offset + 7].toInt() and 0xFF) shl 8),
        isAcknowledgement = (control and 0x80) != 0,
        ackPolicy = (control ushr 5) and 0x03,
        encryption = control and 0x07,
        commandSet = data[offset + 9].toInt() and 0xFF,
        commandId = data[offset + 10].toInt() and 0xFF,
        body = data.copyOfRange(offset + 11, offset + total - 2),
      )
    }
  }

  private var buffer = ByteArray(4 * 1024)
  private var head = 0
  private var tail = 0
  private var resynchronising = false

  var counters = P3Counters()
    private set

  val buffered: Int get() = tail - head

  fun offer(data: ByteArray, offset: Int = 0, length: Int = data.size - offset): List<P3Frame> {
    require(offset >= 0 && length >= 0 && offset + length <= data.size) { "range outside the array" }
    if (tail + length > buffer.size) {
      if (head > 0) {
        buffer.copyInto(buffer, 0, head, tail)
        tail -= head
        head = 0
      }
      if (tail + length > buffer.size) {
        var size = buffer.size
        while (size < tail + length) {
          size *= 2
        }
        buffer = buffer.copyOf(size)
      }
    }
    data.copyInto(buffer, tail, offset, offset + length)
    tail += length
    return drain()
  }

  fun reset() {
    head = 0
    tail = 0
    resynchronising = false
  }

  private fun drain(): List<P3Frame> {
    val frames = mutableListOf<P3Frame>()
    while (true) {
      val available = tail - head
      if (available < 1) {
        break
      }
      if ((buffer[head].toInt() and 0xFF) != MAGIC) {
        skip(1)
        continue
      }
      if (available < MIN_SIZE) {
        break
      }
      if (!headerCrc.verify(buffer, head, 4)) {
        counters = counters.copy(headerCrcFailures = counters.headerCrcFailures + 1)
        skip(1)
        continue
      }
      val lengthAndVersion = (buffer[head + 1].toInt() and 0xFF) or ((buffer[head + 2].toInt() and 0xFF) shl 8)
      val total = lengthAndVersion and 0x3FF
      if (total < MIN_SIZE) {
        counters = counters.copy(lengthRejections = counters.lengthRejections + 1)
        skip(1)
        continue
      }
      if (available < total) {
        break
      }
      if (!frameCrc.verify(buffer, head, total)) {
        counters = counters.copy(frameCrcFailures = counters.frameCrcFailures + 1)
        // Four bytes, as the controller application does: past the magic and the header it already read
        skip(4)
        continue
      }
      val frame = parse(buffer, head, total)
      head += total
      resynchronising = false
      counters = counters.copy(
        frames = counters.frames + 1,
        frameBytes = counters.frameBytes + total,
        unsupportedEncryption = counters.unsupportedEncryption + if (frame.encryptionUnsupported) 1 else 0,
      )
      frames.add(frame)
    }
    if (head == tail) {
      head = 0
      tail = 0
    } else if (head >= buffer.size / 2) {
      buffer.copyInto(buffer, 0, head, tail)
      tail -= head
      head = 0
    }
    return frames
  }

  private fun skip(bytes: Int) {
    val step = minOf(bytes, tail - head)
    head += step
    counters = counters.copy(
      discardedBytes = counters.discardedBytes + step,
      resynchronisations = counters.resynchronisations + if (resynchronising) 0 else 1,
    )
    resynchronising = true
  }
}

/**
 * The sequence counter of the control frames: it increments, skips 85 because that value equals the magic byte and
 * makes a resynchronisation ambiguous, and wraps at 32768.
 */
class SequenceCounter(private var value: Int = 0) {
  companion object {
    const val SKIPPED = 85
    const val WRAP = 32768
  }

  fun next(): Int {
    var candidate = value + 1
    if (candidate == SKIPPED) {
      candidate += 1
    }
    if (candidate >= WRAP) {
      candidate = 0
    }
    value = candidate
    return candidate
  }

  fun peek(): Int = value
}
