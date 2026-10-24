package app.alextran.immich.djilink

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import app.alextran.immich.MainActivity

/**
 * The entry Android offers when a DJI accessory is plugged in. It brings the application forward, tells an open live
 * screen that the permission was just handed over, and marks the launch ([AttachLaunch]) so that Flutter opens the
 * live screen when it is not open yet; the live screen is where anything happens, and the pilot has to be on it.
 *
 * It is declared disabled in the manifest and is enabled only while a link runs or when the pilot said yes to "Open
 * this screen when the remote is plugged in" ([AttachEntryPolicy]), so this application never appears in the chooser
 * of a pilot who did not ask for it, and never competes with the DJI application for a cable on a phone.
 */
class DjiLinkAttachActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    Log.i("DjiLinkAttach", "an accessory was attached; bringing the application forward")
    // Choosing this application in the chooser hands it the permission: an open page can take the accessory at once
    DjiLinkController.existing()?.onAttachEntry()
    AttachLaunch.mark()
    runCatching {
      startActivity(
        Intent(this, MainActivity::class.java)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      )
    }
    finish()
  }
}
