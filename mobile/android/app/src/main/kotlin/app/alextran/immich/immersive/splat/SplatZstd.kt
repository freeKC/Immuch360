package app.alextran.immich.immersive.splat

import java.io.InputStream

// The ZSTD decoder of the version 4 SPZ files (FreeKC's report of 1 November 2026: axes_v4.spz said the headset does
// not read version 4) behind one interface: zstd-jni (BSD 2-Clause, with zstd under its BSD licence) in the quest
// flavour only (questImplementation in android/app/build.gradle), so that the phone APKs keep their size.
// src/quest/kotlin/.../immersive/splat/SplatZstds.kt holds the object of the decoder, src/phone/... one that has none;
// both are named SplatZstds, so that the code of main compiles in both flavours (the pattern of SplatEngines).

/** The ZSTD decoder, or its absence */
internal interface SplatZstd {
  /** Whether this APK has the decoder */
  val available: Boolean

  /**
   * The bytes the ZSTD frames of [compressed] hold, decompressed as they are read; closing it closes [compressed]. A
   * frame that is damaged or cut throws an IOException (or a RuntimeException of the decoder) while it is read
   */
  fun open(compressed: InputStream): InputStream
}
