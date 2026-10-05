package app.alextran.immich.phoneshare

import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.BaseColumns
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import java.io.File
import java.util.concurrent.Executors

/**
 * Host side of the PhoneShareApi pigeon, for "Share this phone on the network": what Dart needs to serve the gallery
 * (the size, type, name and date of the media without opening them, then a path to read each one from) and the
 * foreground service that keeps the share alive while the screen is off (see [PhoneShareService]).
 *
 * The media are read in place: MediaStore gives their path, which the app reads directly through the media storage of
 * Android 11 and later (and the legacy storage of Android 10) once it may read the photos and videos. When the path
 * cannot be read (a photo outside a partial access, a storage that does not allow it), the media is copied to the
 * cache through its content URI, and the copies are deleted when the share stops.
 */
class PhoneShareApiImpl(context: Context) : PhoneShareApi {
  private val appContext = context.applicationContext

  override fun startKeepAlive(title: String, text: String, stopLabel: String) {
    PhoneShareService.start(appContext, PhoneShareNotificationTexts.of(title, text, stopLabel))
  }

  override fun updateKeepAlive(text: String) {
    PhoneShareService.update(text)
  }

  override fun stopKeepAlive() {
    PhoneShareService.stop(appContext)
  }

  override fun fileInfos(assetIds: List<String>, callback: (Result<List<PhoneShareFileInfo>>) -> Unit) {
    executor.execute {
      val result = runCatching { queryInfos(assetIds) }
      result.exceptionOrNull()?.let { Log.w(TAG, "MediaStore query failed", it) }
      mainHandler.post { callback(result) }
    }
  }

  override fun openFile(assetId: String, callback: (Result<PhoneShareOpenedFile?>) -> Unit) {
    executor.execute {
      val result = runCatching { open(assetId) }
      result.exceptionOrNull()?.let { Log.w(TAG, "Cannot open media $assetId", it) }
      mainHandler.post { callback(result) }
    }
  }

  override fun releaseTemporaryFiles() {
    val folder = File(appContext.cacheDir, CACHE_FOLDER)
    executor.execute {
      if (folder.exists() && !folder.deleteRecursively()) {
        Log.w(TAG, "Some copies of the phone share were not deleted")
      }
    }
  }

  /** One MediaStore query per [CHUNK] ids; ids that are not numbers (no MediaStore id) or gone are left out */
  private fun queryInfos(assetIds: List<String>): List<PhoneShareFileInfo> {
    val ids = assetIds.mapNotNull { it.toLongOrNull() }.distinct()
    val infos = ArrayList<PhoneShareFileInfo>(ids.size)
    for (chunk in ids.chunked(CHUNK)) {
      query(chunk)?.use { cursor ->
        val columns = Columns(cursor)
        while (cursor.moveToNext()) {
          val id = cursor.getLong(columns.id)
          infos.add(
            PhoneShareFileInfo(
              assetId = id.toString(),
              size = cursor.getLongOrZero(columns.size),
              mimeType = cursor.getStringOrNull(columns.mimeType) ?: DEFAULT_MIME_TYPE,
              fileName = cursor.getStringOrNull(columns.displayName) ?: id.toString(),
              // MediaStore keeps seconds
              modifiedMs = cursor.getLongOrZero(columns.dateModified) * 1000L,
            )
          )
        }
      }
    }
    return infos
  }

  private fun open(assetId: String): PhoneShareOpenedFile? {
    val id = assetId.toLongOrNull() ?: return null
    val row =
      query(listOf(id))?.use { cursor ->
        if (!cursor.moveToFirst()) {
          return@use null
        }
        val columns = Columns(cursor)
        MediaRow(
          id = id,
          path = cursor.getStringOrNull(columns.data),
          mimeType = cursor.getStringOrNull(columns.mimeType) ?: DEFAULT_MIME_TYPE,
          displayName = cursor.getStringOrNull(columns.displayName),
          size = cursor.getLongOrZero(columns.size),
        )
      } ?: return null

    val direct = row.path?.let(::File)
    if (direct != null && direct.isFile && direct.canRead()) {
      return PhoneShareOpenedFile(path = direct.absolutePath, size = direct.length(), isTemporary = false)
    }
    return copyToCache(row)
  }

  /** The media of [row] copied to the cache through its content URI; a copy made before is used again */
  private fun copyToCache(row: MediaRow): PhoneShareOpenedFile? {
    val folder = File(appContext.cacheDir, CACHE_FOLDER).apply { mkdirs() }
    val extension = row.displayName?.substringAfterLast('.', "")?.takeIf { it.matches(SAFE_EXTENSION) }
    val target = File(folder, if (extension.isNullOrEmpty()) "${row.id}" else "${row.id}.$extension")
    if (target.isFile && target.length() > 0 && (row.size <= 0 || target.length() == row.size)) {
      return PhoneShareOpenedFile(path = target.absolutePath, size = target.length(), isTemporary = true)
    }
    val uri = contentUriOf(row)
    val partial = File.createTempFile("media-${row.id}-", ".part", folder)
    try {
      val input = appContext.contentResolver.openInputStream(uri) ?: return null
      input.use { source -> partial.outputStream().use { source.copyTo(it, BUFFER_SIZE) } }
      if (!partial.renameTo(target)) {
        // Another read copied it meanwhile
        if (!target.isFile) {
          return null
        }
      }
    } finally {
      partial.delete()
    }
    Log.i(TAG, "Media ${row.id} copied to the cache: its path cannot be read")
    return PhoneShareOpenedFile(path = target.absolutePath, size = target.length(), isTemporary = true)
  }

  private fun query(ids: List<Long>): Cursor? {
    if (ids.isEmpty()) {
      return null
    }
    val selection = "${BaseColumns._ID} IN (${ids.joinToString(",") { "?" }})"
    return appContext.contentResolver.query(
      MediaStore.Files.getContentUri(VOLUME_EXTERNAL),
      PROJECTION,
      selection,
      ids.map { it.toString() }.toTypedArray(),
      null,
    )
  }

  private data class MediaRow(
    val id: Long,
    val path: String?,
    val mimeType: String,
    val displayName: String?,
    val size: Long,
  )

  private class Columns(cursor: Cursor) {
    val id = cursor.getColumnIndexOrThrow(BaseColumns._ID)
    val size = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
    val mimeType = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
    val displayName = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
    val dateModified = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
    @Suppress("DEPRECATION")
    val data = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
  }

  companion object {
    private const val TAG = "PhoneShareApi"
    private const val CACHE_FOLDER = "phone_share"
    private const val CHUNK = 500
    private const val BUFFER_SIZE = 1024 * 1024
    private const val DEFAULT_MIME_TYPE = "application/octet-stream"
    private const val VOLUME_EXTERNAL = "external"
    private val SAFE_EXTENSION = Regex("[A-Za-z0-9]{1,8}")

    @Suppress("DEPRECATION")
    private val PROJECTION =
      arrayOf(
        BaseColumns._ID,
        MediaStore.MediaColumns.SIZE,
        MediaStore.MediaColumns.MIME_TYPE,
        MediaStore.MediaColumns.DISPLAY_NAME,
        MediaStore.MediaColumns.DATE_MODIFIED,
        MediaStore.MediaColumns.DATA,
      )

    /** Two threads: a listing does not wait behind the copy of a large video */
    private val executor = Executors.newFixedThreadPool(2)
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Events towards Flutter, attached by MainActivity for the engine of the app UI and detached when that engine goes
     * away, as for the immersive viewer. The service only finds Flutter through this. Read and written on the main
     * thread.
     */
    @Volatile
    private var events: PhoneShareEvents? = null

    /** The messenger [events] sends through, to detach only the engine that attached */
    private var eventsMessenger: BinaryMessenger? = null

    fun attachEvents(messenger: BinaryMessenger) {
      eventsMessenger = messenger
      events = PhoneShareEvents(messenger)
    }

    /** Drops the events only when they still belong to [messenger], so a newer MainActivity keeps its own */
    fun detachEvents(messenger: BinaryMessenger) {
      if (eventsMessenger === messenger) {
        eventsMessenger = null
        events = null
      }
    }

    /** Tells Flutter the user stopped the share from the notification; nothing without an engine for the app UI */
    fun notifyStopRequested() {
      mainHandler.post {
        val current = events
        if (current == null) {
          Log.i(TAG, "no Flutter engine to tell that the phone share was stopped")
          return@post
        }
        current.stopRequested { result ->
          result.exceptionOrNull()?.let { Log.w(TAG, "Flutter did not get the stop request", it) }
        }
      }
    }

    /** The content URI of a media: images and videos have their own collections, which the copy reads through */
    private fun contentUriOf(row: MediaRow): Uri {
      val collection =
        when {
          row.mimeType.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
          row.mimeType.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
          else -> MediaStore.Files.getContentUri(VOLUME_EXTERNAL)
        }
      return ContentUris.withAppendedId(collection, row.id)
    }

    private fun Cursor.getStringOrNull(column: Int): String? = if (isNull(column)) null else getString(column)

    private fun Cursor.getLongOrZero(column: Int): Long = if (isNull(column)) 0L else getLong(column)
  }
}
