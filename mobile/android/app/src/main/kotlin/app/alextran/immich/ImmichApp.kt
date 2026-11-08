package app.alextran.immich

import android.app.Application
import android.os.Handler
import android.os.Looper
import app.alextran.immich.background.BackgroundEngineLock
import app.alextran.immich.background.BackgroundWorkerApiImpl
import app.alextran.immich.core.AppHealth
import app.alextran.immich.core.JavaCrashRecorder

class ImmichApp : Application() {
  override fun onCreate() {
    super.onCreate()
    // First, the stack of a Java crash of this process is kept for the Logs page; then why the last processes ended is
    // read, on a thread of its own, whatever started this one (the app, a background worker): see AppHealth
    JavaCrashRecorder.install(AppHealth.folder(this))
    AppHealth.collectExits(this)
    // After the process is killed (by user or system), the first trigger (taking a new picture) is lost.
    // Thus, the BackupWorker is not started. If the system kills the process after each initialization
    // (because of low memory etc.), the backup is never performed.
    // As a workaround, we also run a backup check when initializing the application
    Handler(Looper.getMainLooper()).postDelayed({
      // We can only check the engine count and not the status of the lock here,
      // as the previous start might have been killed without unlocking.
      if (BackgroundEngineLock.connectEngines > 0) return@postDelayed
      BackgroundWorkerApiImpl.enqueueBackgroundWorker(this)
    }, 15000)
    // The Flutter injector of the process, taken here on the main thread before any activity or worker starts
    // (FlutterInjectorPin)
    FlutterInjectorPin.pin(this)
  }
}
