package app.alextran.immich.djilink

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import java.io.File
import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject

/**
 * Writes a capture where the pilot can reach it, as three files in Download/Immuch360/dji-link/:
 *
 * - `<id>.bin`, the bytes as they were on the wire;
 * - `<id>.idx.csv`, one line per read and per write with both clocks, because one read is one USB transfer and that
 *   boundary is what a reassembly question needs;
 * - `<id>.json`, the header: the device, the build, the USB environment, the accessory strings, the profile, every
 *   counter at the moment of the export, what the pilot typed about the bench, and the digest of the bytes.
 *
 * When nothing was captured, the header alone is written: "nothing ever opened" is a result too, and the environment
 * that produced it is what explains it.
 *
 * Android 10 and later take the files into the shared downloads; Android 8 and 9 have no downloads collection for an
 * application, so the files go to the application's own folder on the shared storage, whose path the page shows.
 *
 * Nothing is uploaded anywhere. A capture holds serial numbers and possibly a position, so it stays on the device and
 * on the pilot's own computer, and it is never committed to the fork.
 */
object CaptureExport {
  const val FOLDER = "Immuch360/dji-link"

  data class Result(
    val ok: Boolean,
    val bytes: Long,
    val binPath: String? = null,
    val indexPath: String? = null,
    val headerPath: String? = null,
    val sha256: String? = null,
    val error: String? = null,
    /** True when only the header was written, because nothing was captured */
    val headerOnly: Boolean = false,
  )

  fun write(
    context: Context,
    snapshot: CaptureSnapshot,
    environment: UsbEnvironmentReport,
    identity: AccessoryIdentity?,
    profile: DeviceProfile?,
    link: Map<String, Any?>,
    notes: Map<String, String?>,
    id: String = "dji-link-" + android.text.format.DateFormat.format("yyyyMMdd-HHmmss", System.currentTimeMillis()),
  ): Result {
    val digest = snapshot.sha256()
    val header = headerJson(id, snapshot, digest, environment, identity, profile, link, notes)
    if (snapshot.bytes.isEmpty() && snapshot.entries.isEmpty()) {
      return try {
        val json = writeFile(context, "$id.json", "application/json", header.toByteArray())
        Result(ok = true, bytes = 0, headerPath = json, sha256 = digest, headerOnly = true)
      } catch (error: Throwable) {
        Result(ok = false, bytes = 0, error = error.message ?: error.javaClass.simpleName)
      }
    }
    return try {
      val bin = writeFile(context, "$id.bin", "application/octet-stream", snapshot.bytes)
      val index = writeFile(context, "$id.idx.csv", "text/csv", snapshot.indexCsv().toByteArray())
      val json = writeFile(context, "$id.json", "application/json", header.toByteArray())
      Result(
        ok = true,
        bytes = snapshot.bytes.size.toLong(),
        binPath = bin,
        indexPath = index,
        headerPath = json,
        sha256 = digest,
      )
    } catch (error: Throwable) {
      Result(ok = false, bytes = 0, error = error.message ?: error.javaClass.simpleName)
    }
  }

  private fun writeFile(context: Context, name: String, mime: String, bytes: ByteArray): String =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      writeDownloads(context, name, mime, bytes)
    } else {
      writeOwnFolder(context, name, bytes)
    }

  @RequiresApi(Build.VERSION_CODES.Q)
  private fun writeDownloads(context: Context, name: String, mime: String, bytes: ByteArray): String {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, name)
      put(MediaStore.MediaColumns.MIME_TYPE, mime)
      put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
      put(MediaStore.MediaColumns.IS_PENDING, 1)
    }
    val collection: Uri = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    // A device whose downloads collection refuses the insert still has a folder of its own
    val target = resolver.insert(collection, values) ?: return writeOwnFolder(context, name, bytes)
    var done = false
    try {
      (resolver.openOutputStream(target) ?: throw IOException("$name cannot be written")).use { it.write(bytes) }
      resolver.update(target, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
      done = true
      return "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/$name"
    } finally {
      if (!done) {
        runCatching { resolver.delete(target, null, null) }
      }
    }
  }

  /** The application's own folder on the shared storage, which needs no permission on any version */
  private fun writeOwnFolder(context: Context, name: String, bytes: ByteArray): String {
    val base = context.getExternalFilesDir(null) ?: context.filesDir
    val folder = File(base, "dji-link").apply { mkdirs() }
    val file = File(folder, name)
    file.writeBytes(bytes)
    return file.absolutePath
  }

  fun headerJson(
    id: String,
    snapshot: CaptureSnapshot,
    digest: String,
    environment: UsbEnvironmentReport,
    identity: AccessoryIdentity?,
    profile: DeviceProfile?,
    link: Map<String, Any?>,
    notes: Map<String, String?>,
  ): String {
    val root = JSONObject()
    root.put("id", id)
    root.put("takenAtWallMs", System.currentTimeMillis())
    root.put("sha256", digest)
    root.put("bytes", snapshot.bytes.size)
    root.put("totalBytes", snapshot.totalBytes)
    root.put("droppedBytes", snapshot.droppedBytes)
    root.put("records", snapshot.entries.size)
    root.put("headerOnly", snapshot.bytes.isEmpty() && snapshot.entries.isEmpty())
    root.put("formatNotes", "store/m2/dji-2026-10-21/p2/protocol.md")
    root.put("sendPathEnabled", DjiLinkBuild.SEND_ENABLED)
    root.put(
      "device",
      JSONObject()
        .put("manufacturer", environment.deviceManufacturer)
        .put("model", environment.deviceModel)
        .put("fingerprint", environment.buildFingerprint)
        .put("androidRelease", environment.androidRelease)
        .put("sdkInt", environment.sdkInt)
        .put("appVersion", environment.appVersion)
        .put("flavour", environment.flavour),
    )
    root.put(
      "usb",
      JSONObject()
        .put("accessoryFeature", environment.hasAccessoryFeature)
        .put("hostFeature", environment.hasHostFeature)
        .put("accessoryNodeExists", environment.accessoryNodeExists)
        .put("accessoryNodeWritable", environment.accessoryNodeWritable)
        .put("futureUsbLibrary", environment.futureUsbLibraryPresent)
        .put("adbEnabled", environment.adbEnabled)
        .put("stateKnown", environment.usbStateKnown)
        .put("connected", environment.usbConnected)
        .put("configured", environment.usbConfigured)
        .put("accessoryMode", environment.usbAccessoryMode)
        .put("adbFunction", environment.usbAdbFunction)
        .put("djiApplicationInstalled", environment.djiApplicationInstalled)
        .put("accessoriesListed", environment.accessoriesListed)
        .put("chargeCurrentMicroAmps", environment.chargeCurrentMicroAmps ?: JSONObject.NULL),
    )
    root.put(
      "accessory",
      JSONObject()
        .put("manufacturer", identity?.manufacturer ?: JSONObject.NULL)
        .put("model", identity?.model ?: JSONObject.NULL)
        .put("description", identity?.description ?: JSONObject.NULL)
        .put("version", identity?.version ?: JSONObject.NULL)
        .put("serial", identity?.serial ?: JSONObject.NULL),
    )
    val capabilities = JSONArray()
    profile?.capabilities?.forEach { (capability, state) ->
      capabilities.put(
        JSONObject()
          .put("capability", capability.name)
          .put("support", state.support.name)
          .put("provenance", state.provenance?.observationId ?: JSONObject.NULL),
      )
    }
    root.put(
      "profile",
      JSONObject()
        .put("id", profile?.id ?: JSONObject.NULL)
        .put("label", profile?.label ?: JSONObject.NULL)
        .put("note", profile?.note ?: JSONObject.NULL)
        .put("capabilities", capabilities),
    )
    val counters = JSONObject()
    link.forEach { (key, value) -> counters.put(key, value ?: JSONObject.NULL) }
    root.put("link", counters)
    val bench = JSONObject()
    notes.forEach { (key, value) -> bench.put(key, value ?: JSONObject.NULL) }
    root.put("bench", bench)
    return root.toString(2)
  }
}
