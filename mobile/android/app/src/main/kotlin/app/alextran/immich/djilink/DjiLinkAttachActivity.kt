package app.alextran.immich.djilink

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import app.alextran.immich.MainActivity

/**
 * The entry Android offers when a DJI accessory is plugged in. It brings the application forward and tells an open
 * link page that the permission was just handed over; the page is where anything happens, and the pilot has to be on
 * it.
 *
 * It is declared disabled in the manifest and is enabled only while the diagnostics switch is on
 * ([DjiLinkApiImpl.setAttachEntryEnabled]), so this application never appears in the chooser of a pilot who did not
 * ask for it, and never competes with the DJI application for a cable on a phone.
 */
class DjiLinkAttachActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    Log.i("DjiLinkAttach", "an accessory was attached; bringing the application forward")
    // Choosing this application in the chooser hands it the permission: an open page can take the accessory at once
    DjiLinkController.existing()?.onAttachEntry()
    runCatching {
      startActivity(
        Intent(this, MainActivity::class.java)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      )
    }
    finish()
  }
}
