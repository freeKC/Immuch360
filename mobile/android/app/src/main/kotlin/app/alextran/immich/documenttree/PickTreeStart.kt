package app.alextran.immich.documenttree

/**
 * Where the folder picker opens (pickTree): the document id of a folder of the storage of the device, which
 * DocumentsContract.EXTRA_INITIAL_URI takes as a document of ExternalStorageProvider ("primary:Download" for
 * "Download", where Browse a folder opens). Null when no folder is asked, or when the folder named is not a plain path
 * of that storage (an empty or "." or ".." part, a volume id, a backslash, a control character): the picker then
 * opens where it opens by itself. Pure, tested by PickTreeStartTest.
 */
internal object PickTreeStart {
  fun documentId(folder: String?): String? {
    val path = folder?.trim()?.trim('/') ?: return null
    if (path.isEmpty()) return null
    val plain = path.split('/').all { part ->
      part.isNotEmpty() && part != "." && part != ".." && part.none { it == ':' || it == '\\' || it.code < 32 }
    }
    return if (plain) "primary:$path" else null
  }
}
