package app.alextran.immich.spherical

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest

/**
 * The stabilisation table of the video a 360° player plays, kept on disk for the player that the system restores
 * after the process died (issue 14). The table comes from Flutter, which is not running then: Android brings back the
 * player alone, without the activity of the app below it, so nobody could send the table again and the video would
 * play raw, the button hidden. The player writes its table when it goes to the background and reads it back when it is
 * restored; it deletes it when it closes. The last [MAX_FILES] tables are kept, each under the SHA-256 of its URL (a
 * URL may carry a key, so it is not written anywhere). Pure Kotlin, so that the unit tests run without a device; the
 * player calls it off the main thread, a table of an hour of video being a few megabytes.
 */
internal class StabilizationStore(private val directory: File) {
  companion object {
    /** Tables kept, as many as the messages of the inbox */
    const val MAX_FILES = StabilizationInbox.MAX_URLS

    /** "STB1": the format of the file, a table of another format is not read */
    private const val MAGIC = 0x53544231

    /** The summary is for the logs: a longer one is cut */
    private const val MAX_SUMMARY_CHARS = 4000

    /** The bytes of a frame: its time and its four values */
    private const val FRAME_BYTES = 8 + 4 * 8

    private const val SUFFIX = ".bin"

    /** The name of the file of [url]: the SHA-256 of the URL in hexadecimal */
    fun fileName(url: String): String =
      MessageDigest.getInstance("SHA-256")
        .digest(url.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) } + SUFFIX
  }

  /**
   * Writes the table of [message] in place of the one before for its URL, and forgets the oldest past [MAX_FILES].
   * False when the message holds no table (nothing is written) or the write failed.
   */
  fun save(message: StabilizationInbox.Message): Boolean {
    val times = message.timesUs
    val corrections = message.corrections
    if (message.table == null || times == null || corrections == null || corrections.size != 4 * times.size) {
      return false
    }
    if (!directory.isDirectory && !directory.mkdirs()) return false
    val target = File(directory, fileName(message.url))
    val partial = File(directory, target.name + ".part")
    try {
      DataOutputStream(BufferedOutputStream(FileOutputStream(partial))).use { out ->
        out.writeInt(MAGIC)
        out.writeBoolean(message.enabled)
        out.writeInt(times.size)
        for (time in times) out.writeLong(time)
        for (value in corrections) out.writeDouble(value)
        val summary = message.summary
        out.writeBoolean(summary != null)
        if (summary != null) out.writeUTF(summary.take(MAX_SUMMARY_CHARS))
      }
    } catch (e: IOException) {
      partial.delete()
      return false
    }
    // Whole or not at all: a player restored while a write was cut finds the table before or none
    if (!partial.renameTo(target)) {
      partial.delete()
      return false
    }
    forgetOldest()
    return true
  }

  /**
   * The table kept for [url] as the inbox message it came in (a motion track, its table, the setting then), or null
   * when there is none or it cannot be read; [onRefused] then says why, for the logs
   */
  fun load(url: String, onRefused: (String) -> Unit = {}): StabilizationInbox.Message? {
    val file = File(directory, fileName(url))
    if (!file.isFile) return null
    try {
      DataInputStream(BufferedInputStream(FileInputStream(file))).use { input ->
        if (input.readInt() != MAGIC) {
          onRefused("not a table of this player")
          return null
        }
        val enabled = input.readBoolean()
        val frames = input.readInt()
        if (frames <= 0 || frames.toLong() * FRAME_BYTES > file.length()) {
          onRefused("$frames frames in ${file.length()} bytes")
          return null
        }
        val times = LongArray(frames) { input.readLong() }
        val corrections = DoubleArray(4 * frames) { input.readDouble() }
        val summary = if (input.readBoolean()) input.readUTF() else null
        val table = StabilizationTable.of(times, corrections, onRefused) ?: return null
        return StabilizationInbox.Message(url, enabled, true, table, summary, times, corrections)
      }
    } catch (e: EOFException) {
      onRefused("the file ends early")
    } catch (e: IOException) {
      onRefused(e.toString())
    }
    return null
  }

  /** Forgets the table of [url]: its player closed */
  fun delete(url: String) {
    File(directory, fileName(url)).delete()
  }

  private fun forgetOldest() {
    val files = directory.listFiles { file -> file.name.endsWith(SUFFIX) } ?: return
    files.sortedByDescending { it.lastModified() }.drop(MAX_FILES).forEach { it.delete() }
  }
}
