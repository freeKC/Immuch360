package app.alextran.immich

import java.io.IOException
import java.nio.ByteBuffer

const val INITIAL_BUFFER_SIZE = 32 * 1024

/**
 * [pointer], the address malloc gave for [size] bytes, or an OutOfMemoryError after [release] when it gave none: the
 * address 0 handed to NativeBuffer.wrap aborts the process (NewDirectByteBuffer with a null address), while the error
 * lets the callers of a decode retry at half the size or answer that the photo did not decode
 */
fun checkAllocated(pointer: Long, size: Long, release: () -> Unit = {}): Long {
  if (pointer == 0L) {
    release()
    throw OutOfMemoryError("No native memory for a buffer of $size bytes")
  }
  return pointer
}

object NativeBuffer {
  init {
    System.loadLibrary("native_core_ffi")
  }

  @JvmStatic
  external fun allocate(size: Int): Long

  @JvmStatic
  external fun free(address: Long)

  @JvmStatic
  external fun realloc(address: Long, size: Int): Long

  @JvmStatic
  external fun wrap(address: Long, capacity: Int): ByteBuffer

  @JvmStatic
  external fun copy(buffer: ByteBuffer, destAddress: Long, offset: Int, length: Int)

  @JvmStatic
  external fun createGlobalRef(obj: Any): Long
}

class NativeByteBuffer(initialCapacity: Int) {
  var pointer = NativeBuffer.allocate(initialCapacity)
  var capacity = initialCapacity
  var offset = 0

  // A failed realloc keeps the buffer as it was, so that the caller frees it, and is an IOException: the download
  // fails as any other (both callers catch Exception), where a pointer of 0 would have had the next read write to a
  // low address
  inline fun ensureHeadroom() {
    if (offset == capacity) {
      val grown = NativeBuffer.realloc(pointer, capacity * 2)
      if (grown == 0L) {
        throw IOException("No native memory to grow a buffer of $capacity bytes")
      }
      pointer = grown
      capacity *= 2
    }
  }

  inline fun wrapRemaining() = NativeBuffer.wrap(pointer + offset, capacity - offset)

  inline fun advance(bytesRead: Int) {
    offset += bytesRead
  }

  inline fun free() {
    if (pointer != 0L) {
      NativeBuffer.free(pointer)
      pointer = 0L
    }
  }
}
