package app.alextran.immich.immersive

import java.io.File

/**
 * What the immersive viewer deletes from the cache of the app as it starts: the originals and the splats it downloaded
 * or wrote for earlier viewings, the files at the top of the cache whose name starts with one of [prefixes]. Nothing
 * else: the folders of the cache stay, the one of the splat viewer included, where the scenes of the splat photos of
 * the Immich server are kept for the next opening (plan of 3 November 2026, lot L4), the headset reading them from
 * there as files of its own.
 */
internal object ImmersiveCacheCleaning {
  /** The entries of [entries] (the listing of the cache, null when it could not be listed) to delete */
  fun leftovers(entries: Array<File>?, prefixes: List<String>): List<File> =
    entries.orEmpty().filter { entry -> prefixes.any { entry.name.startsWith(it) } }
}
