package app.alextran.immich.mpv

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

// The phone flavour has no libmpv in release 46 (the Quest first, FreeKC on 11 November 2026): nothing is registered,
// and the Dart side (android_mpv.dart) gets no answer on its channel, which it reads as no libmpv in this build.

/** See the top of this file */
internal object MpvPlayers {
  @Suppress("UNUSED_PARAMETER")
  fun register(engine: FlutterEngine, context: Context) = Unit
}
