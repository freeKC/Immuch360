package app.alextran.immich.immersive.splat

import com.github.luben.zstd.ZstdInputStreamNoFinalizer
import java.io.InputStream

/**
 * The ZSTD decoder of the tests on the JVM: zstd-jni, the library the quest flavour ships (SplatZstds of src/quest),
 * from its jar for the JVM (testImplementation in android/app/build.gradle). The phone flavour, which the unit tests
 * build, has no decoder of its own.
 */
internal object JvmZstd : SplatZstd {
  override val available = true

  override fun open(compressed: InputStream): InputStream = ZstdInputStreamNoFinalizer(compressed)
}
