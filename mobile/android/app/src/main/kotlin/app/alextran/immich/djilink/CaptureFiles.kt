package app.alextran.immich.djilink

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File

/** One capture that can be played, as the page lists it */
data class CaptureFile(
  val name: String,
  val binUri: String,
  val indexUri: String,
  val bytes: Long,
  val modifiedMs: Long,
  /** export, replayFolder or chosen */
  val origin: String,
)

/**
 * Where the captures to play are: the exports of this app in Download/Immuch360/dji-link/ (the MediaStore entries it
 * owns, so an app updated in place still lists them and a reinstalled one does not), the pairs of files placed in its
 * replay folder Android/data/com.aprogsys.immuch360/files/dji-link-replay/ (where adb push can put one), and on
 * Android 8 and 9 the folder its exports go to. A capture is a .bin with the .idx.csv of the same name.
 */
object CaptureFiles {
  const val REPLAY_FOLDER = "dji-link-replay"
  private const val BIN = ".bin"
  private const val INDEX = ".idx.csv"

  fun replayFolder(context: Context): File? =
    context.getExternalFilesDir(REPLAY_FOLDER)?.also { it.mkdirs() }

  fun list(context: Context): List<CaptureFile> {
    val found = mutableListOf<CaptureFile>()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      found.addAll(runCatching { exports(context) }.getOrDefault(emptyList()))
    }
    replayFolder(context)?.let { found.addAll(inFolder(it, "replayFolder")) }
    context.getExternalFilesDir(null)?.let { found.addAll(inFolder(File(it, "dji-link"), "export")) }
    return found.distinctBy { it.binUri }.sortedByDescending { it.modifiedMs }
  }

  private fun inFolder(folder: File, origin: String): List<CaptureFile> {
    val files = folder.listFiles() ?: return emptyList()
    return files.filter { it.isFile && it.name.endsWith(BIN) }.mapNotNull { bin ->
      val index = File(folder, bin.name.removeSuffix(BIN) + INDEX)
      if (!index.isFile) {
        return@mapNotNull null
      }
      CaptureFile(
        name = bin.name.removeSuffix(BIN),
        binUri = Uri.fromFile(bin).toString(),
        indexUri = Uri.fromFile(index).toString(),
        bytes = bin.length(),
        modifiedMs = bin.lastModified(),
        origin = origin,
      )
    }
  }

  private fun exports(context: Context): List<CaptureFile> {
    val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    val projection = arrayOf(
      MediaStore.MediaColumns._ID,
      MediaStore.MediaColumns.DISPLAY_NAME,
      MediaStore.MediaColumns.SIZE,
      MediaStore.MediaColumns.DATE_MODIFIED,
    )
    val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
    val arguments = arrayOf("${Environment.DIRECTORY_DOWNLOADS}/${CaptureExport.FOLDER}%")
    data class Row(val uri: Uri, val name: String, val size: Long, val modifiedMs: Long)
    val rows = mutableListOf<Row>()
    context.contentResolver.query(collection, projection, selection, arguments, null)?.use { cursor ->
      val id = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
      val name = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
      val size = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
      val modified = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
      while (cursor.moveToNext()) {
        rows.add(
          Row(
            uri = ContentUris.withAppendedId(collection, cursor.getLong(id)),
            name = cursor.getString(name) ?: continue,
            size = cursor.getLong(size),
            modifiedMs = cursor.getLong(modified) * 1000,
          )
        )
      }
    }
    val byName = rows.associateBy { it.name }
    return rows.filter { it.name.endsWith(BIN) }.mapNotNull { bin ->
      val base = bin.name.removeSuffix(BIN)
      val index = byName[base + INDEX] ?: return@mapNotNull null
      CaptureFile(base, bin.uri.toString(), index.uri.toString(), bin.size, bin.modifiedMs, "export")
    }
  }

  /** Pairs a .bin and a .idx.csv among files chosen in the system picker, by their display names */
  fun pairChosen(context: Context, uris: List<Uri>): CaptureFile? {
    val named = uris.map { it to (displayName(context, it) ?: it.lastPathSegment ?: "") }
    val bin = named.firstOrNull { it.second.endsWith(BIN) } ?: return null
    val base = bin.second.removeSuffix(BIN)
    val index = named.firstOrNull { it.second == base + INDEX } ?: named.firstOrNull { it.second.endsWith(INDEX) }
      ?: return null
    return CaptureFile(
      name = base,
      binUri = bin.first.toString(),
      indexUri = index.first.toString(),
      bytes = size(context, bin.first),
      modifiedMs = System.currentTimeMillis(),
      origin = "chosen",
    )
  }

  private fun displayName(context: Context, uri: Uri): String? = runCatching {
    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) cursor.getString(0) else null
    }
  }.getOrNull()

  private fun size(context: Context, uri: Uri): Long = runCatching {
    context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) cursor.getLong(0) else 0L
    } ?: 0L
  }.getOrDefault(0L)

  /** The bytes behind a content or file address; a capture is at most a few tens of megabytes */
  fun read(context: Context, address: String): ByteArray {
    val uri = Uri.parse(address)
    if (uri.scheme == "file" || uri.scheme == null) {
      return File(uri.path ?: address).readBytes()
    }
    return context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
      ?: throw java.io.IOException("cannot be read")
  }
}
