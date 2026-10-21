package app.alextran.immich.documenttree

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Point
import android.hardware.usb.UsbManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.FileChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

private const val TAG = "DocumentTreePlugin"

// Request code of the folder picker, "DT"
private const val PICK_REQUEST = 0x4454

// A provider that lists a folder in batches (MTP) is waited for while new files keep coming: until none came for
// LOADING_QUIET_MS, at most LOADING_CAP_MS in all; LOADING_LOOK_MS between two looks at it
private const val LOADING_QUIET_MS = 10_000L
private const val LOADING_CAP_MS = 120_000L
private const val LOADING_LOOK_MS = 1_000L

// Largest read at once, what the uploads ask (readWholeFile reads 8 MB chunks)
private const val MAX_READ = 8 * 1024 * 1024

// Files kept open between reads, and how long an unused one stays open
private const val MAX_OPEN = 2
private const val IDLE_CLOSE_MS = 30_000L

// A file that cannot be read at a position and stands further than this from its start costs a long read to open
// again: it is the last one closed to make room for another (the file an upload streams)
private const val CHEAP_REOPEN = 16L * 1024 * 1024

// The largest file opened to learn whether a device reads parts of files (see learnSeekable)
private const val PROBE_MAX_SIZE = 8L * 1024 * 1024

private const val COPY_BUFFER = 1024 * 1024
private const val PROGRESS_EVERY_MS = 250L

private const val EXTERNAL_STORAGE = "com.android.externalstorage.documents"
private const val MTP = "com.android.mtp.documents"

private val PROJECTION = arrayOf(
  Document.COLUMN_DOCUMENT_ID,
  Document.COLUMN_DISPLAY_NAME,
  Document.COLUMN_MIME_TYPE,
  Document.COLUMN_SIZE,
  Document.COLUMN_LAST_MODIFIED,
  Document.COLUMN_FLAGS,
)

private class CopyCancelled : Exception("cancelled")

/**
 * The folders picked in the system picker, read through the Storage Access Framework: a DJI drone or a card reader as
 * a USB drive (ExternalStorageProvider), a DJI RC 2 or another phone in File transfer mode (MtpDocumentsProvider). One
 * query per folder (ids, names, types, sizes, dates and flags at once), reads at a position when the file allows it
 * (a USB drive, an MTP device that reads parts of files) and from the start otherwise, two files kept open, and copies
 * into the gallery streamed from the file. No permission: the picker grants the folder chosen.
 */
class DocumentTreePlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener, DocumentTreeApi {
  private var context: Context? = null
  private var activity: Activity? = null
  private var activityBinding: ActivityPluginBinding? = null
  private var events: DocumentTreeEvents? = null
  private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

  // The reads of files, one at a time in the order they come: an upload asks for the next chunk while it sends the
  // current one, and a file that can only be read from its start must get them in order
  private val readExecutor = Executors.newSingleThreadExecutor()
  private val readDispatcher = readExecutor.asCoroutineDispatcher()
  private val mainHandler = Handler(Looper.getMainLooper())
  private var pendingPick: ((Result<TreePick?>) -> Unit)? = null

  // The files open for reading, the least recently used first; the closer of the idle ones runs while one is open
  private val openFiles = LinkedHashMap<String, OpenFile>(4, 0.75f, true)
  private val closer = Executors.newSingleThreadScheduledExecutor()
  private var closerTask: ScheduledFuture<*>? = null
  private val runningCopies = ConcurrentHashMap.newKeySet<Long>()
  private val cancelledCopies = ConcurrentHashMap.newKeySet<Long>()
  private var usbReceiver: BroadcastReceiver? = null

  // Whether the files of each tree can be read at a position, learned from the first file opened
  private val treeSeekable = ConcurrentHashMap<String, Boolean>()

  private class OpenFile(val treeUri: String, val pfd: ParcelFileDescriptor, val seekable: Boolean) {
    val stream = FileInputStream(pfd.fileDescriptor)
    val channel: FileChannel = stream.channel
    private val closed = AtomicBoolean(false)

    // Where a file that cannot be read at a position stands
    @Volatile var position = 0L
    @Volatile var lastUsed = SystemClock.elapsedRealtime()

    /**
     * Closes the file from any thread, without waiting for a read under way: closing the channel first makes such a
     * read stop with a ClosedChannelException (a device that stopped answering)
     */
    fun close() {
      if (!closed.compareAndSet(false, true)) {
        return
      }
      try {
        channel.close()
      } catch (_: IOException) {
      }
      try {
        stream.close()
      } catch (_: IOException) {
      }
      try {
        pfd.close()
      } catch (_: IOException) {
      }
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    events = DocumentTreeEvents(binding.binaryMessenger)
    DocumentTreeApi.setUp(binding.binaryMessenger, this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    DocumentTreeApi.setUp(binding.binaryMessenger, null)
    watchUsb(false)
    closer.shutdownNow()
    readExecutor.shutdownNow()
    val closing = synchronized(openFiles) {
      closerTask = null
      openFiles.values.toList().also { openFiles.clear() }
    }
    closing.forEach { it.close() }
    ioScope.cancel()
    events = null
    context = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    activityBinding = binding
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

  override fun onDetachedFromActivity() {
    activityBinding?.removeActivityResultListener(this)
    activityBinding = null
    activity = null
  }

  // Picking

  override fun pickTree(callback: (Result<TreePick?>) -> Unit) {
    val current = activity
    if (current == null) {
      callback(Result.failure(FlutterError("no_activity", "The folder picker needs the app on screen", null)))
      return
    }
    if (pendingPick != null) {
      callback(Result.failure(FlutterError("busy", "The folder picker is open already", null)))
      return
    }
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
      Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
    )
    pendingPick = callback
    try {
      current.startActivityForResult(intent, PICK_REQUEST)
    } catch (e: ActivityNotFoundException) {
      pendingPick = null
      callback(Result.failure(FlutterError("no_picker", "This device has no folder picker", null)))
    }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != PICK_REQUEST) {
      return false
    }
    val callback = pendingPick ?: return true
    pendingPick = null
    val uri = data?.data
    val ctx = context
    if (resultCode != Activity.RESULT_OK || uri == null || ctx == null) {
      callback(Result.success(null))
      return true
    }
    ioScope.launch {
      try {
        // Kept across restarts while the folder stays plugged in; a provider that refuses only costs a new pick
        ctx.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
      } catch (e: SecurityException) {
        Log.i(TAG, "No persisted grant for the folder picked: ${e.message}")
      }
      callback(runCatching { describe(ctx, uri) })
    }
    return true
  }

  override fun reopen(treeUri: String, callback: (Result<TreePick?>) -> Unit) {
    val ctx = context ?: return callback(Result.success(null))
    ioScope.launch {
      val uri = Uri.parse(treeUri)
      val granted = ctx.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }
      if (!granted) {
        callback(Result.success(null))
        return@launch
      }
      val pick = try {
        // The folder itself answers only while its drive or device is plugged in
        queryOne(ctx.contentResolver, DocumentsContract.buildDocumentUriUsingTree(uri, treeDocumentId(uri)))
          ?.let { describe(ctx, uri) }
      } catch (e: Exception) {
        Log.i(TAG, "The folder picked before cannot be read now: ${e.message}")
        null
      }
      callback(Result.success(pick))
    }
  }

  override fun release(treeUri: String) {
    closeTree(treeUri)
    val ctx = context ?: return
    try {
      ctx.contentResolver.releasePersistableUriPermission(Uri.parse(treeUri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
    } catch (e: SecurityException) {
      Log.i(TAG, "No grant to give back: ${e.message}")
    }
  }

  /** The tree [uri] as the page shows it: the volume or the device it is on, the folder, where it is */
  private fun describe(ctx: Context, uri: Uri): TreePick {
    val documentId = treeDocumentId(uri)
    val folder = try {
      queryOne(ctx.contentResolver, DocumentsContract.buildDocumentUriUsingTree(uri, documentId))?.name
    } catch (e: Exception) {
      null
    } ?: documentId.substringAfterLast('/').substringAfter(':')
    var kind = "other"
    var title: String? = null
    when (uri.authority) {
      EXTERNAL_STORAGE -> {
        // "primary:DCIM" on the storage of the phone, "1A2B-3C4D:DCIM" on a card or a USB drive
        val volumeId = documentId.substringBefore(':')
        if (volumeId == "primary" || volumeId.startsWith("home")) {
          kind = "internal"
        } else {
          kind = "usb"
        }
        val storage = ctx.getSystemService(Context.STORAGE_SERVICE) as StorageManager
        val volume = storage.storageVolumes.firstOrNull { volume ->
          if (kind == "internal") volume.isPrimary else volume.uuid.equals(volumeId, ignoreCase = true)
        }
        title = volume?.getDescription(ctx)
      }
      MTP -> {
        kind = "mtp"
        // The name of the device, as it tells it over USB ("DJI RC 2", "Pixel 8")
        val usb = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager
        title = try {
          usb?.deviceList?.values?.firstNotNullOfOrNull { it.productName?.takeIf(String::isNotBlank) }
        } catch (e: SecurityException) {
          null
        }
      }
    }
    return TreePick(treeUri = uri.toString(), title = title ?: folder, folderName = folder, kind = kind)
  }

  // Listing

  override fun list(treeUri: String, documentId: String?, callback: (Result<DocListing>) -> Unit) {
    val ctx = context ?: return callback(Result.failure(FlutterError("no_context", null, null)))
    ioScope.launch {
      callback(
        guarded(ctx, treeUri) {
          val uri = Uri.parse(treeUri)
          val (entries, complete) = queryChildren(ctx.contentResolver, uri, documentId ?: treeDocumentId(uri))
          learnSeekable(ctx.contentResolver, treeUri, entries)
          DocListing(entries = entries.map { withSeekable(treeUri, it) }, complete = complete)
        },
      )
    }
  }

  override fun stat(treeUri: String, documentId: String?, callback: (Result<DocEntry>) -> Unit) {
    val ctx = context ?: return callback(Result.failure(FlutterError("no_context", null, null)))
    ioScope.launch {
      callback(
        guarded(ctx, treeUri) {
          val uri = Uri.parse(treeUri)
          val document = DocumentsContract.buildDocumentUriUsingTree(uri, documentId ?: treeDocumentId(uri))
          withSeekable(treeUri, queryOne(ctx.contentResolver, document) ?: throw IOException("Not found: $documentId"))
        },
      )
    }
  }

  /**
   * The children of [documentId], and whether they are all there: one query, asked again while the provider says it is
   * still loading (an MTP device lists 20 files at a time and tells when more came) and new files keep coming, see
   * [LOADING_QUIET_MS] and [LOADING_CAP_MS]
   */
  private fun queryChildren(
    resolver: ContentResolver,
    treeUri: Uri,
    documentId: String,
  ): Pair<List<DocEntry>, Boolean> {
    val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
    val start = SystemClock.elapsedRealtime()
    var lastCount = -1
    var lastGrowth = start
    while (true) {
      val cursor = resolver.query(children, PROJECTION, null, null, null)
        ?: throw IOException("The folder cannot be listed")
      cursor.use {
        val loading = it.extras?.getBoolean(DocumentsContract.EXTRA_LOADING, false) == true
        val now = SystemClock.elapsedRealtime()
        if (it.count > lastCount) {
          lastCount = it.count
          lastGrowth = now
        }
        val remaining = minOf(lastGrowth + LOADING_QUIET_MS, start + LOADING_CAP_MS) - now
        if (!loading || remaining <= 0) {
          if (loading) {
            Log.w(TAG, "The folder was still loading after ${(now - start) / 1000} s, ${it.count} files: listed so")
          }
          return readEntries(it) to !loading
        }
        val changed = CountDownLatch(1)
        val observer = object : ContentObserver(mainHandler) {
          override fun onChange(selfChange: Boolean) = changed.countDown()
        }
        it.registerContentObserver(observer)
        try {
          changed.await(minOf(remaining, LOADING_LOOK_MS), TimeUnit.MILLISECONDS)
        } finally {
          it.unregisterContentObserver(observer)
        }
      }
    }
  }

  private fun queryOne(resolver: ContentResolver, document: Uri): DocEntry? =
    resolver.query(document, PROJECTION, null, null, null)?.use { readEntries(it).firstOrNull() }

  private fun readEntries(cursor: Cursor): List<DocEntry> {
    val entries = ArrayList<DocEntry>(cursor.count)
    while (cursor.moveToNext()) {
      val id = cursor.getString(0) ?: continue
      val name = cursor.getString(1) ?: continue
      val mime = cursor.getString(2)
      val flags = if (cursor.isNull(5)) 0 else cursor.getInt(5)
      entries.add(
        DocEntry(
          documentId = id,
          name = name,
          isDirectory = mime == Document.MIME_TYPE_DIR,
          mimeType = mime,
          size = if (cursor.isNull(3)) null else cursor.getLong(3),
          lastModifiedMs = if (cursor.isNull(4)) null else cursor.getLong(4).takeIf { it > 0 },
          supportsThumbnail = flags and Document.FLAG_SUPPORTS_THUMBNAIL != 0,
        ),
      )
    }
    return entries
  }

  /** [entry] with whether its file can be read at a position, as far as its tree is known */
  private fun withSeekable(treeUri: String, entry: DocEntry): DocEntry =
    if (entry.isDirectory) entry else entry.copy(seekable = treeSeekable[treeUri])

  /**
   * Learns whether the files of [treeUri] can be read at a position, once per tree: always on a USB drive or a card
   * (a real file), else by opening the smallest file of [entries] that is small enough, since a device that sends
   * whole files only may send all of it once opened
   */
  private fun learnSeekable(resolver: ContentResolver, treeUri: String, entries: List<DocEntry>) {
    if (treeSeekable.containsKey(treeUri)) {
      return
    }
    val uri = Uri.parse(treeUri)
    if (uri.authority == EXTERNAL_STORAGE) {
      treeSeekable[treeUri] = true
      return
    }
    val probe = entries
      .filter { !it.isDirectory && (it.size ?: 0L) in 1L..PROBE_MAX_SIZE }
      .minByOrNull { it.size ?: 0L } ?: return
    try {
      resolver.openFileDescriptor(DocumentsContract.buildDocumentUriUsingTree(uri, probe.documentId), "r")?.use {
        treeSeekable[treeUri] = isSeekable(it)
      }
    } catch (e: Exception) {
      Log.i(TAG, "Could not tell whether the files of $treeUri can be read at a position: ${e.message}")
    }
  }

  private fun isSeekable(pfd: ParcelFileDescriptor): Boolean = try {
    Os.lseek(pfd.fileDescriptor, 0, OsConstants.SEEK_CUR)
    true
  } catch (e: ErrnoException) {
    false
  }

  // Reading

  override fun read(treeUri: String, documentId: String, offset: Long, length: Long, callback: (Result<ByteArray>) -> Unit) {
    val ctx = context ?: return callback(Result.failure(FlutterError("no_context", null, null)))
    ioScope.launch(readDispatcher) {
      callback(
        guarded(ctx, treeUri) {
          val file = openFile(ctx.contentResolver, treeUri, documentId)
          synchronized(file) {
            val wanted = minOf(length, MAX_READ.toLong()).toInt()
            if (file.seekable) readAt(file, offset, wanted) else readOn(ctx.contentResolver, treeUri, documentId, file, offset, wanted)
          }
        },
      )
    }
  }

  private fun openFile(resolver: ContentResolver, treeUri: String, documentId: String): OpenFile {
    val key = "$treeUri\n$documentId"
    synchronized(openFiles) {
      // Marked as used under the lock, so that the closer of idle files cannot take it in between
      openFiles[key]?.let {
        it.lastUsed = SystemClock.elapsedRealtime()
        return it
      }
    }
    val document = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
    val pfd = resolver.openFileDescriptor(document, "r") ?: throw IOException("The file cannot be opened")
    val seekable = isSeekable(pfd)
    if (!seekable) {
      // A pipe: the device cannot read parts of a file (MTP without GetPartialObject)
      Log.i(TAG, "$documentId can only be read from its start")
    }
    treeSeekable[treeUri] = seekable
    val file = OpenFile(treeUri, pfd, seekable)
    val evicted = ArrayList<OpenFile>()
    synchronized(openFiles) {
      openFiles.put(key, file)?.let(evicted::add)
      while (openFiles.size > MAX_OPEN) {
        val victim = OpenFilesPolicy.victim(
          openFiles.entries.map { OpenFileState(it.key, it.value.seekable, it.value.position) },
          keep = key,
        ) ?: break
        openFiles.remove(victim)?.let(evicted::add)
      }
      scheduleCloserLocked()
    }
    evicted.forEach { it.close() }
    return file
  }

  private fun readAt(file: OpenFile, offset: Long, length: Int): ByteArray {
    val buffer = ByteBuffer.allocate(length)
    var position = offset
    while (buffer.hasRemaining()) {
      val count = file.channel.read(buffer, position)
      if (count <= 0) {
        break
      }
      position += count
    }
    return if (buffer.position() == length) buffer.array() else buffer.array().copyOf(buffer.position())
  }

  /**
   * Reads a file that cannot be read at a position: on from where it stands, reading through the bytes before
   * [offset] (a pipe cannot skip them either), or from its start again for a position behind it. Each step marks the
   * file as used: only a read that stopped moving is taken for a stall by the closer of idle files.
   */
  private fun readOn(
    resolver: ContentResolver,
    treeUri: String,
    documentId: String,
    open: OpenFile,
    offset: Long,
    length: Int,
  ): ByteArray {
    var file = open
    val plan = SequentialReadPlan.of(file.position, offset)
    if (plan.reopen) {
      Log.i(TAG, "Opening $documentId again to read at $offset from ${file.position}")
      closeFile(treeUri, documentId)
      file = openFile(resolver, treeUri, documentId)
    }
    val scratch = ByteBuffer.allocate(minOf(COPY_BUFFER.toLong(), maxOf(offset - file.position, 1L)).toInt())
    while (file.position < offset) {
      scratch.clear()
      scratch.limit(minOf(scratch.capacity().toLong(), offset - file.position).toInt())
      val count = file.channel.read(scratch)
      if (count <= 0) {
        return ByteArray(0)
      }
      file.position += count
      file.lastUsed = SystemClock.elapsedRealtime()
    }
    val buffer = ByteBuffer.allocate(length)
    while (buffer.hasRemaining()) {
      val count = file.channel.read(buffer)
      if (count <= 0) {
        break
      }
      file.position += count
      file.lastUsed = SystemClock.elapsedRealtime()
    }
    return if (buffer.position() == length) buffer.array() else buffer.array().copyOf(buffer.position())
  }

  private fun closeFile(treeUri: String, documentId: String) {
    synchronized(openFiles) {
      openFiles.remove("$treeUri\n$documentId").also { stopCloserIfIdleLocked() }
    }?.close()
  }

  override fun closeTree(treeUri: String) {
    val closing = synchronized(openFiles) {
      val keys = openFiles.filterValues { it.treeUri == treeUri }.keys
      keys.mapNotNull { openFiles.remove(it) }.also { stopCloserIfIdleLocked() }
    }
    if (closing.isNotEmpty()) {
      // Never on the main thread: closing a file whose read is stuck may wait for that read to give up
      ioScope.launch { closing.forEach { it.close() } }
    }
  }

  /**
   * Closes the files unused for [IDLE_CLOSE_MS]; a read stuck that long on a device that stopped answering stops then
   * with the code "stalled"
   */
  private fun closeIdle() {
    val now = SystemClock.elapsedRealtime()
    val closing = synchronized(openFiles) {
      val keys = openFiles.filterValues { now - it.lastUsed > IDLE_CLOSE_MS }.keys
      keys.mapNotNull { openFiles.remove(it) }.also { stopCloserIfIdleLocked() }
    }
    closing.forEach { it.close() }
  }

  /** Starts the closer of idle files, if needed; with [openFiles] held */
  private fun scheduleCloserLocked() {
    if (closerTask != null) {
      return
    }
    closerTask = try {
      closer.scheduleWithFixedDelay({ closeIdle() }, IDLE_CLOSE_MS / 3, IDLE_CLOSE_MS / 3, TimeUnit.MILLISECONDS)
    } catch (e: RejectedExecutionException) {
      null
    }
  }

  /** Stops the closer of idle files once none is open; with [openFiles] held */
  private fun stopCloserIfIdleLocked() {
    if (openFiles.isEmpty()) {
      closerTask?.cancel(false)
      closerTask = null
    }
  }

  override fun thumbnail(treeUri: String, documentId: String, size: Long, callback: (Result<ByteArray?>) -> Unit) {
    val ctx = context ?: return callback(Result.success(null))
    ioScope.launch {
      val bytes = try {
        val document = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
        val side = size.toInt().coerceIn(64, 1024)
        DocumentsContract.getDocumentThumbnail(ctx.contentResolver, document, Point(side, side), null)?.let { bitmap ->
          val out = ByteArrayOutputStream()
          bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
          bitmap.recycle()
          out.toByteArray()
        }
      } catch (e: Exception) {
        null
      }
      callback(Result.success(bytes))
    }
  }

  // Keeping on the device

  override fun copyToGallery(
    copyId: Long,
    treeUri: String,
    documentId: String,
    name: String,
    mimeType: String,
    album: String,
    takenAtMs: Long,
    callback: (Result<String>) -> Unit,
  ) {
    val ctx = context ?: return callback(Result.failure(FlutterError("no_context", null, null)))
    runningCopies.add(copyId)
    ioScope.launch {
      try {
        val source = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), documentId)
        val total = queryOne(ctx.contentResolver, source)?.size ?: -1L
        val copied = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          copyIntoMediaStore(ctx, source, copyId, name, mimeType, album, takenAtMs, total)
        } else {
          copyIntoDcim(ctx, source, copyId, name, mimeType, album, takenAtMs, total)
        }
        callback(Result.success(copied))
      } catch (e: CopyCancelled) {
        callback(Result.failure(FlutterError("cancelled", "The copy was cancelled", null)))
      } catch (e: Exception) {
        callback(Result.failure(failure(ctx, treeUri, e)))
      } finally {
        runningCopies.remove(copyId)
        cancelledCopies.remove(copyId)
      }
    }
  }

  override fun cancelCopy(copyId: Long) {
    // A copy that ended already leaves nothing to cancel, and no id behind
    if (runningCopies.contains(copyId)) {
      cancelledCopies.add(copyId)
    }
  }

  @RequiresApi(Build.VERSION_CODES.Q)
  private fun copyIntoMediaStore(
    ctx: Context,
    source: Uri,
    copyId: Long,
    name: String,
    mimeType: String,
    album: String,
    takenAtMs: Long,
    total: Long,
  ): String {
    val resolver = ctx.contentResolver
    val isMedia = isGalleryMedia(mimeType)
    val collection = when {
      mimeType.startsWith("video/") -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
      mimeType.startsWith("image/") -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
      else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    }
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, name)
      put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
      put(
        MediaStore.MediaColumns.RELATIVE_PATH,
        "${if (isMedia) Environment.DIRECTORY_DCIM else Environment.DIRECTORY_DOWNLOADS}/$album",
      )
      put(MediaStore.MediaColumns.IS_PENDING, 1)
      if (takenAtMs > 0 && isMedia) {
        put(MediaStore.MediaColumns.DATE_TAKEN, takenAtMs)
      }
    }
    val target = resolver.insert(collection, values) ?: throw IOException("The gallery did not take $name")
    var done = false
    try {
      (resolver.openInputStream(source) ?: throw IOException("$name cannot be read")).use { input ->
        (resolver.openOutputStream(target) ?: throw IOException("The gallery cannot be written")).use { output ->
          copy(input, output, copyId, total)
        }
      }
      resolver.update(target, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
      done = true
      return target.toString()
    } finally {
      if (!done) {
        try {
          resolver.delete(target, null, null)
        } catch (e: Exception) {
          Log.w(TAG, "Could not remove the copy of $name left unfinished", e)
        }
      }
    }
  }

  /**
   * Whether a file of [mimeType] goes to the gallery (DCIM); any other file goes to Download, where its name is kept as
   * it is (a raw 360° video of a DJI camera, which the gallery would rename into an MP4 and the device backup would then
   * send to Immich as a flat video)
   */
  private fun isGalleryMedia(mimeType: String) =
    mimeType.startsWith("image/") || mimeType.startsWith("video/")

  /** Android 8 and 9: a file in DCIM, written with the storage permission the app asks with the photos one */
  @Suppress("DEPRECATION")
  private fun copyIntoDcim(
    ctx: Context,
    source: Uri,
    copyId: Long,
    name: String,
    mimeType: String,
    album: String,
    takenAtMs: Long,
    total: Long,
  ): String {
    val folder = File(
      Environment.getExternalStoragePublicDirectory(
        if (isGalleryMedia(mimeType)) Environment.DIRECTORY_DCIM else Environment.DIRECTORY_DOWNLOADS,
      ),
      album,
    )
    if (!folder.isDirectory && !folder.mkdirs()) {
      throw IOException("Cannot make the album $album")
    }
    val dot = name.lastIndexOf('.')
    val stem = if (dot > 0) name.substring(0, dot) else name
    val extension = if (dot > 0) name.substring(dot) else ""
    var file = File(folder, name)
    var index = 1
    while (file.exists()) {
      file = File(folder, "$stem ($index)$extension")
      index++
    }
    var done = false
    try {
      (ctx.contentResolver.openInputStream(source) ?: throw IOException("$name cannot be read")).use { input ->
        FileOutputStream(file).use { output -> copy(input, output, copyId, total) }
      }
      if (takenAtMs > 0) {
        file.setLastModified(takenAtMs)
      }
      done = true
    } finally {
      if (!done) {
        file.delete()
      }
    }
    MediaScannerConnection.scanFile(ctx, arrayOf(file.path), arrayOf(mimeType), null)
    return Uri.fromFile(file).toString()
  }

  private fun copy(input: InputStream, output: OutputStream, copyId: Long, total: Long) {
    val buffer = ByteArray(COPY_BUFFER)
    var copied = 0L
    var told = 0L
    while (true) {
      if (cancelledCopies.contains(copyId)) {
        throw CopyCancelled()
      }
      val count = input.read(buffer)
      if (count < 0) {
        break
      }
      output.write(buffer, 0, count)
      copied += count
      val now = SystemClock.elapsedRealtime()
      if (now - told >= PROGRESS_EVERY_MS) {
        told = now
        tellProgress(copyId, copied, total)
      }
    }
    tellProgress(copyId, copied, total)
  }

  private fun tellProgress(copyId: Long, bytes: Long, total: Long) {
    mainHandler.post { events?.onCopyProgress(copyId, bytes, total) {} }
  }

  // Plug and unplug

  override fun watchUsb(watch: Boolean) {
    val ctx = context ?: return
    if (!watch) {
      usbReceiver?.let {
        try {
          ctx.unregisterReceiver(it)
        } catch (_: IllegalArgumentException) {
        }
      }
      usbReceiver = null
      return
    }
    if (usbReceiver != null) {
      return
    }
    val receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        val attached = when (intent.action) {
          UsbManager.ACTION_USB_DEVICE_ATTACHED, Intent.ACTION_MEDIA_MOUNTED -> true
          else -> false
        }
        events?.onUsbChanged(attached) {}
      }
    }
    val devices = IntentFilter().apply {
      addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
      addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
    }
    // The volumes of USB drives and cards, which come once mounted, after the device itself
    val volumes = IntentFilter().apply {
      addAction(Intent.ACTION_MEDIA_MOUNTED)
      addAction(Intent.ACTION_MEDIA_UNMOUNTED)
      addAction(Intent.ACTION_MEDIA_REMOVED)
      addAction(Intent.ACTION_MEDIA_BAD_REMOVAL)
      addAction(Intent.ACTION_MEDIA_EJECT)
      addDataScheme("file")
    }
    for (filter in listOf(devices, volumes)) {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        // System broadcasts only
        ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
      } else {
        ctx.registerReceiver(receiver, filter)
      }
    }
    usbReceiver = receiver
  }

  // Errors

  private fun treeDocumentId(uri: Uri): String = DocumentsContract.getTreeDocumentId(uri)

  private inline fun <T> guarded(ctx: Context, treeUri: String, action: () -> T): Result<T> = try {
    Result.success(action())
  } catch (e: Exception) {
    Result.failure(failure(ctx, treeUri, e))
  }

  /**
   * "stalled" for a read stopped because its file was closed under it (a device that stopped answering, see
   * [closeIdle]), "unplugged" when the folder picked does not answer anymore, "io" for any other failure
   */
  private fun failure(ctx: Context, treeUri: String, error: Exception): FlutterError {
    if (error is ClosedChannelException) {
      // Not asked whether the folder still answers: the device that stalled may stall that query too
      return FlutterError("stalled", "The device stopped answering", null)
    }
    val uri = Uri.parse(treeUri)
    val reachable = try {
      queryOne(ctx.contentResolver, DocumentsContract.buildDocumentUriUsingTree(uri, treeDocumentId(uri))) != null
    } catch (e: Exception) {
      false
    }
    if (!reachable) {
      closeTree(treeUri)
      return FlutterError("unplugged", error.message ?: error.javaClass.simpleName, null)
    }
    return FlutterError("io", error.message ?: error.javaClass.simpleName, null)
  }
}

/**
 * Where a read of a file that can only be read from its start (a pipe) begins: on from where the file stands when the
 * offset is at or after it, reading through the bytes in between, which is never more than opening it again would read;
 * from its start again only for an offset behind it
 */
internal data class SequentialReadPlan(val reopen: Boolean, val skip: Long) {
  companion object {
    fun of(position: Long, offset: Long): SequentialReadPlan = if (offset < position) {
      SequentialReadPlan(reopen = true, skip = offset)
    } else {
      SequentialReadPlan(reopen = false, skip = offset - position)
    }
  }
}

/** What [OpenFilesPolicy] knows of an open file */
internal data class OpenFileState(val key: String, val seekable: Boolean, val position: Long)

internal object OpenFilesPolicy {
  /**
   * The file to close among [files] (the least recently used first) to make room, never [keep]: the least recently used
   * one that costs little to open again, a file read at a position or a pipe within [CHEAP_REOPEN] of its start, so
   * that a pipe far into its file (the one an upload streams) stays open while the tiles read the heads of others; the
   * least recently used one when all are costly
   */
  fun victim(files: List<OpenFileState>, keep: String): String? {
    val others = files.filter { it.key != keep }
    return (others.firstOrNull { it.seekable || it.position <= CHEAP_REOPEN } ?: others.firstOrNull())?.key
  }
}
