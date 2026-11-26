package app.alextran.immich.playrelay

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The channel of "Play on…" sending from the phone (release 53, lib/providers/play_on_screen/phone_relay.provider.dart):
 * "start" with the texts of the notification while a lease of the relay lives, "stop" once none does; the notification's
 * Stop comes back as "stopRequested". For the engine of the app UI only.
 */
object PlayRelayChannel {
  private const val NAME = "app.immuch360/play_relay"

  @Volatile
  private var channel: MethodChannel? = null

  fun attach(context: Context, messenger: BinaryMessenger) {
    val app = context.applicationContext
    channel =
      MethodChannel(messenger, NAME).apply {
        setMethodCallHandler { call, result ->
          when (call.method) {
            "start" -> {
              PlayRelayService.start(
                app,
                call.argument<String>("title"),
                call.argument<String>("text"),
                call.argument<String>("stop"),
                call.argument<String>("channel"),
              )
              result.success(null)
            }
            "stop" -> {
              PlayRelayService.stop(app)
              result.success(null)
            }
            else -> result.notImplemented()
          }
        }
      }
  }

  fun detach(messenger: BinaryMessenger) {
    MethodChannel(messenger, NAME).setMethodCallHandler(null)
    channel = null
  }

  /** The Stop of the notification: Flutter ends the play on the screen and the leases */
  fun notifyStopRequested() {
    Handler(Looper.getMainLooper()).post { channel?.invokeMethod("stopRequested", null) }
  }
}
