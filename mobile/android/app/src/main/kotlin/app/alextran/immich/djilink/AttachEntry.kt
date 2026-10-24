package app.alextran.immich.djilink

/**
 * Whether the entry that puts this application in Android's question for a plugged DJI remote is enabled
 * (p2/design-ux-phone-2026-10-24.md, 8.4). While a link runs it always is, so that the pilot on the live screen can
 * answer that question. Otherwise only when the pilot said yes to "Open this screen when the remote is plugged in" and
 * the DJI live video setting is on: a pilot who flies with DJI Fly and never said yes is never offered this application
 * for the cable. Pure, so that it is unit tested.
 */
object AttachEntryPolicy {
  fun enabled(linkRunning: Boolean, openOnPlug: Boolean, settingOn: Boolean): Boolean =
    linkRunning || (openOnPlug && settingOn)
}

/**
 * The two answers [AttachEntryPolicy] needs when no link runs, kept in the app's own preferences so that they hold
 * across process deaths. They decide which application Android offers for the cable, and nothing else: nothing here
 * reads from the remote or writes to it.
 */
class AttachEntryPreferences(private val store: KeyValueStore) {
  companion object {
    private const val OPEN_ON_PLUG = "attach.openOnPlug"
    private const val SETTING_OFF = "attach.liveSettingOff"
  }

  /** Off by default: the pilot says yes once, on the plug step or in Advanced */
  var openOnPlug: Boolean
    get() = store.read(OPEN_ON_PLUG) == "1"
    set(value) = store.write(OPEN_ON_PLUG, if (value) "1" else null)

  /** On by default, as the setting is */
  var settingOn: Boolean
    get() = store.read(SETTING_OFF) != "1"
    set(value) = store.write(SETTING_OFF, if (value) null else "1")

  fun entryEnabled(linkRunning: Boolean): Boolean = AttachEntryPolicy.enabled(linkRunning, openOnPlug, settingOn)
}

/**
 * The plug of a remote that brought the application forward through its attach entry, told once to Flutter, which
 * then opens the live screen. Lives as long as the process: a cold start through the entry marks it in the new one.
 */
object AttachLaunch {
  private var pending = false

  @Synchronized
  fun mark() {
    pending = true
  }

  @Synchronized
  fun take(): Boolean {
    val was = pending
    pending = false
    return was
  }
}
