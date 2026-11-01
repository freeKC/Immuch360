package app.alextran.immich.immersive.splat

import com.github.luben.zstd.ZstdInputStreamNoFinalizer
import java.io.InputStream

// The ZSTD decoder of the quest flavour (FreeKC's report of 1 November 2026): zstd-jni 1.5.7-3 of Luben Karavelov
// (com.github.luben:zstd-jni, BSD 2-Clause), which carries zstd 1.5.7 of Meta (dual licensed BSD or GPLv2: the app
// takes it under its BSD licence), see licenses/zstd-jni/README.md. Its native library is the only part of it the APK
// adds (about 600 KB in the arm64 Quest APK). The pure Java decoders of aircompressor were tried first: they read
// fields of sun.misc.Unsafe that Android does not have (exploration of 1 November 2026, on the Android 16 emulator).

/** zstd-jni: the frames of a stream decompressed by the native zstd library, no finalizer, closed by the reader */
internal object SplatZstds : SplatZstd {
  override val available = true

  override fun open(compressed: InputStream): InputStream = ZstdInputStreamNoFinalizer(compressed)
}
