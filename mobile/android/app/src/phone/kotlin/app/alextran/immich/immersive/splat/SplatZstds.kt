package app.alextran.immich.immersive.splat

import java.io.InputStream

// The phone flavour ships no ZSTD decoder: the version 4 SPZ files are read in the quest flavour only, where the splat
// module is, so that the phone APKs keep their size. A splat says it is not in this version of the app there
// (SplatGate). Same object name and shape as src/quest/kotlin/.../immersive/splat/SplatZstds.kt, so that the code of
// main compiles in both flavours.

internal object SplatZstds : SplatZstd {
  override val available = false

  override fun open(compressed: InputStream): InputStream =
    throw UnsupportedOperationException("this version of the app has no ZSTD decoder: it is in the Quest version")
}
