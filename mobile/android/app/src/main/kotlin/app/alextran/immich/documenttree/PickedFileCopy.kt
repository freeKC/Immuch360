package app.alextran.immich.documenttree

import java.io.File

/**
 * Where a file picked with pickFile is copied: the folder of the cache it names, emptied first so that it holds that
 * copy only, under the name of the file made safe for a path (no separator, no control character, at most
 * [MAX_NAME] characters, its extension kept). Pure, tested by PickedFileCopyTest.
 */
internal object PickedFileCopy {
  const val MAX_NAME = 120

  /** [name] as a file name: "file" when it is blank */
  fun safeName(name: String?): String {
    val cleaned = name.orEmpty().map { if (it == '/' || it == '\\' || it == ':' || it.code < 32) '_' else it }
      .joinToString("").trim().trimStart('.')
    if (cleaned.isEmpty()) return "file"
    if (cleaned.length <= MAX_NAME) return cleaned
    val dot = cleaned.lastIndexOf('.')
    val extension = if (dot > 0 && cleaned.length - dot <= 10) cleaned.substring(dot) else ""
    return cleaned.take(MAX_NAME - extension.length) + extension
  }

  /** The folder [folder] of [cacheDir], made safe and emptied, and the file of [name] in it */
  fun targetFor(cacheDir: File, folder: String, name: String?): File {
    val directory = File(cacheDir, safeName(folder))
    directory.deleteRecursively()
    directory.mkdirs()
    return File(directory, safeName(name))
  }
}
