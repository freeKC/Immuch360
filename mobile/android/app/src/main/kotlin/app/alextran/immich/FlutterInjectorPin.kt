package app.alextran.immich

import android.app.Activity
import android.app.Application
import android.util.Log
import io.flutter.FlutterInjector

private const val TAG = "FlutterInjectorPin"

/**
 * The FlutterInjector of the process, taken on the main thread by ImmichApp before any activity or worker starts.
 *
 * FlutterInjector.instance() builds its injector lazily, on a plain static field without a lock. Two threads calling
 * it for the first time together each build one, with its own FlutterLoader, and the last write wins. A background
 * worker built by WorkManager on its own thread during a cold start of MainActivity did that: the activity started
 * the loader of one injector and read the path of the app bundle from the other, never started, and failed with a
 * NullPointerException in FlutterLoader.findAppBundlePath (Play cluster b91d14). Since Flutter 3.29 no
 * FlutterApplication starts the loader in Application.onCreate any more; [pin] does it again, the workaround of
 * flutter#174433.
 */
object FlutterInjectorPin {
  @Volatile
  private var pinned: FlutterInjector? = null

  /** How many times an activity found another injector than the one pinned before: should stay 0 */
  @Volatile
  var replacements = 0
    private set

  /** From Application.onCreate, on the main thread: takes the injector and starts loading the engine library */
  fun pin(app: Application) {
    val injector = FlutterInjector.instance()
    pinned = injector
    // Starts loading libflutter and the assets on Flutter's own executor; the part on this thread is small
    injector.flutterLoader().startInitialization(app)
  }

  /**
   * From MainActivity.onCreate, before super.onCreate, which reads the Flutter loader to start the engine: logs a
   * replaced injector, and makes sure the loader the activity will read is started, whichever it is. Starting it sets
   * what findAppBundlePath reads; the engine of the activity completes its initialization with the shell arguments
   * of its intent, as before.
   */
  fun checkBeforeActivity(activity: Activity) {
    val current = FlutterInjector.instance()
    val pinned = pinned
    if (pinned != null && current !== pinned) {
      // Counted once per new injector: the next activities compare with this one
      this.pinned = current
      replacements++
      Log.w(TAG, "Flutter injector replaced since the start of the process ($replacements)")
    }
    // Does nothing when this loader has started already, the usual case since pin()
    current.flutterLoader().startInitialization(activity.applicationContext)
  }
}
