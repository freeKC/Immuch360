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
 * It is declared disabled in the manifest and enabled while a link runs, or while "Open this screen when the remote is
 * plugged in" and the DJI live video setting are on ([AttachEntryPolicy]), both on by default on a phone since 25
 * October, never on a TV or the Quest. With DJI Fly on the phone too, Android then asks which application opens the
 * remote; turning the switch off in Advanced takes this application out of that question.
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
