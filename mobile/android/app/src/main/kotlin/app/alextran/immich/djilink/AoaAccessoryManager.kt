package app.alextran.immich.djilink

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream

/**
 * The platform side of the link: the broadcasts, the accessory list, the permission, the open, the liveness probe and
 * the retries.
 *
 * The timings are the ones the DJI controller application uses (p2/protocol.md, section 8), because they are the only
 * known good ones for this hardware, and every one of them is a named constant here so that a capture can change one
 * without touching the logic.
 *
 * Several things differ from that application on purpose. The whole accessory list is looked at, not only its first
 * entry, so that a device nobody has described still reaches the page. The permission action belongs to this
 * application, never to DJI; the answer is read from the broadcast and confirmed with [UsbManager.hasPermission], and
 * [PermissionPolicy] decides when a dialog may open at all: one at a time, never again after a refusal unless the
 * pilot asks, and not on top of the system chooser of a fresh plug. Nothing is written for the first
 * [QUIET_AFTER_OPEN_MS] after an open, so that the question "does the remote speak first" has a clean answer on the
 * page. A blocked probe write stops the probing, and failed probes never close a link that is still reading.
 */
interface LinkEvents {
  fun onState(state: LinkState, reason: LinkReason, argument: String?)
  fun onIdentity(identity: AccessoryIdentity?, profile: DeviceProfile?)

  /** A descriptor was obtained; called on the main thread before the reader thread starts */
  fun onOpened()

  /** The descriptor of the last [onOpened] is gone */
  fun onClosed(reason: LinkReason)
  fun onBytes(data: ByteArray, length: Int)
  fun onWrite(data: ByteArray, isProbe: Boolean)
  fun onProbe(result: ProbeResult)
}

class AoaAccessoryManager(
  private val context: Context,
  private val events: LinkEvents,
  private val profiles: ProfileRegistry = ProfileRegistry(),
  private val handler: Handler = Handler(Looper.getMainLooper()),
  private val permissions: PermissionPolicy = PermissionPolicy(),
) {
  companion object {
    private const val TAG = "DjiLinkAccessory"

    /** Our own permission action. Never DJI's: a broadcast action belongs to the application that defines it. */
    const val PERMISSION_ACTION = "com.aprogsys.immuch360.djilink.USB_PERMISSION"

    /** First attempt after the page registers */
    const val FIRST_ATTEMPT_MS = 2_000L

    /** Retry while nothing is connected */
    const val RETRY_MS = 2_000L

    /** Retry after a disconnect */
    const val RETRY_AFTER_DISCONNECT_MS = 3_000L

    /** First liveness probe after a successful open, as the controller application has it */
    const val FIRST_PROBE_MS = 2_000L

    /** Between two liveness probes */
    const val PROBE_INTERVAL_MS = 1_000L

    /** The sixth failure in a row declares a disconnect, unless reads still arrive; five are tolerated */
    const val PROBE_FAILURES_TO_DISCONNECT = 6

    /** Repeated USB state broadcasts inside this window count as one */
    const val USB_STATE_DEBOUNCE_MS = 300L

    /**
     * Stage 1 writes nothing at all for this long after an open, which the controller application does not do. It is
     * there to answer one question with no doubt: does anything arrive before we have sent a single byte.
     */
    const val QUIET_AFTER_OPEN_MS = 20_000L
  }

  private val usb: UsbManager? = context.getSystemService(Context.USB_SERVICE) as? UsbManager

  private var receiver: BroadcastReceiver? = null
  private var descriptor: ParcelFileDescriptor? = null
  private var accessory: UsbAccessory? = null
  private var lastUsbStateMs = 0L

  /** The probe's own thread, opened by [start] and closed by [stop]; the answer comes back to the handler */
  private val probeWorker = ProbeWorker()

  /** Reads counted by the transport when the last probe answer came back, to tell a silent link from a busy one */
  private var readsAtLastProbe = 0L

  var transport: AoaTransport? = null
    private set
  var state: LinkState = LinkState.ABSENT
    private set
  var reason: LinkReason = LinkReason.LOOKING
    private set
  var identity: AccessoryIdentity? = null
    private set
  var profile: DeviceProfile? = null
    private set
  var attempts = 0L
    private set

  /** Descriptors opened since [start] */
  var opens = 0L
    private set
  var probesSent = 0L
    private set
  var probeFailures = 0L
    private set
  var consecutiveProbeFailures = 0
    private set
  var lastProbeCallMs = 0L
    private set

  /** True once a probe write blocked: no further probe is queued behind it on this descriptor */
  var probesHalted = false
    private set
  var openedAtMs: Long? = null
    private set

  /** Set by the reader thread, read by the page */
  @Volatile
  var firstByteMs: Long? = null
    private set

  private val attemptRunnables: Map<PermissionPolicy.Trigger, Runnable> =
    PermissionPolicy.Trigger.entries.associateWith { trigger -> Runnable { connectIfPossible(trigger) } }
  private val probeTick = Runnable { runProbe() }

  /** Starts looking. Does nothing to the aircraft and sends nothing until the quiet window has passed. */
  fun start() {
    if (receiver != null) {
      return
    }
    probeWorker.open()
    opens = 0
    val filter = IntentFilter().apply {
      addAction(PERMISSION_ACTION)
      addAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
      addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
      addAction(UsbEnvironment.USB_STATE_ACTION)
    }
    val created = object : BroadcastReceiver() {
      // The sticky USB state is replayed at registration; it says nothing new and would skip the first wait
      override fun onReceive(context: Context, intent: Intent) = onBroadcast(intent, isInitialStickyBroadcast)
    }
    receiver = created
    ContextCompat.registerReceiver(context, created, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    val environment = UsbEnvironment.read(context)
    if (!environment.transportPossible) {
      publish(LinkState.UNSUPPORTED_TRANSPORT, LinkReason.NO_ACCESSORY_FEATURE)
      return
    }
    publish(LinkState.ABSENT, LinkReason.LOOKING)
    schedule(PermissionPolicy.Trigger.START, FIRST_ATTEMPT_MS)
  }

  fun stop() {
    cancelAttempts()
    handler.removeCallbacks(probeTick)
    receiver?.let { runCatching { context.unregisterReceiver(it) } }
    receiver = null
    closeDescriptor(LinkReason.PAGE_CLOSED)
    permissions.onGone()
    probeWorker.close()
  }

  /** The pilot asked for another go without unplugging anything: a refused permission may be asked again */
  fun retryNow() {
    schedule(PermissionPolicy.Trigger.PILOT, 0)
  }

  /** The pilot picked this application in the system chooser of a plug, which hands the permission over */
  fun onAttachEntry() {
    schedule(PermissionPolicy.Trigger.ATTACH_ENTRY, 0)
  }

  private fun schedule(trigger: PermissionPolicy.Trigger, delayMs: Long) {
    if (receiver == null) {
      return
    }
    val runnable = attemptRunnables.getValue(trigger)
    handler.removeCallbacks(runnable)
    handler.postDelayed(runnable, delayMs)
  }

  private fun cancelAttempts() {
    attemptRunnables.values.forEach { handler.removeCallbacks(it) }
  }

  private fun onBroadcast(intent: Intent, initialSticky: Boolean) {
    when (intent.action) {
      UsbEnvironment.USB_STATE_ACTION -> {
        if (initialSticky) {
          return
        }
        val now = System.currentTimeMillis()
        if (now - lastUsbStateMs < USB_STATE_DEBOUNCE_MS) {
          return
        }
        lastUsbStateMs = now
        schedule(PermissionPolicy.Trigger.USB_STATE, 0)
      }
      UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
        closeDescriptor(LinkReason.DETACHED)
        permissions.onGone()
        publish(LinkState.ABSENT, LinkReason.DETACHED)
        cancelAttempts()
        schedule(PermissionPolicy.Trigger.PERIODIC, RETRY_AFTER_DISCONNECT_MS)
      }
      // A fresh plug, if a device ever delivers it as a broadcast: the chooser may be up, so it waits like a state
      UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> schedule(PermissionPolicy.Trigger.USB_STATE, 0)
      PERMISSION_ACTION -> onPermissionResult(intent)
      else -> Unit
    }
  }

  private fun onPermissionResult(intent: Intent) {
    val answered = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
    val current = accessory ?: listedCandidate()
    // The extra says what the dialog answered; the manager says whether the permission is actually held
    val held = current != null && usb?.hasPermission(current) == true
    Log.i(TAG, "permission answer: granted=$answered held=$held")
    permissions.onResult(granted = answered && held)
    if (answered && held) {
      schedule(PermissionPolicy.Trigger.PERMISSION_RESULT, 0)
      return
    }
    publish(LinkState.PERMISSION_DENIED, LinkReason.PERMISSION_REFUSED)
  }

  private fun listedCandidate(): UsbAccessory? {
    val list = runCatching { usb?.accessoryList?.toList() ?: emptyList() }.getOrDefault(emptyList())
    return pick(list)
  }

  // The platform documents at most one entry, and the reference application only ever reads the first. The whole
  // list is read here, and a DJI accessory anywhere in it is preferred over whatever came first, so that a device
  // that does list more than one still reaches the right end of the cable.
  private fun pick(list: List<UsbAccessory>): UsbAccessory? =
    list.firstOrNull { it.manufacturer.equals(ProfileRegistry.MANUFACTURER, ignoreCase = true) } ?: list.firstOrNull()

  private fun connectIfPossible(trigger: PermissionPolicy.Trigger) {
    if (receiver == null || transport?.isRunning == true) {
      return
    }
    attempts += 1
    val manager = usb
    if (manager == null) {
      publish(LinkState.UNSUPPORTED_TRANSPORT, LinkReason.NO_USB_SERVICE)
      return
    }
    // Documented to hold at most one entry; every entry is looked at and logged anyway
    val list = runCatching { manager.accessoryList?.toList() ?: emptyList() }.getOrDefault(emptyList())
    val candidate = pick(list)
    if (candidate == null) {
      permissions.onGone()
      if (identity != null) {
        identity = null
        profile = null
        events.onIdentity(null, null)
      }
      publish(LinkState.ABSENT, LinkReason.NOTHING_LISTED)
      schedule(PermissionPolicy.Trigger.PERIODIC, RETRY_MS)
      return
    }
    for (listed in list) {
      Log.i(
        TAG,
        "accessory listed: manufacturer=${listed.manufacturer} model=${listed.model} " +
          "description=${listed.description} version=${listed.version}",
      )
    }
    val read = AccessoryIdentity(
      manufacturer = candidate.manufacturer,
      model = candidate.model,
      description = candidate.description,
      version = candidate.version,
      serial = runCatching { candidate.serial }.getOrNull(),
      uri = candidate.uri,
    )
    if (read != identity) {
      identity = read
      profile = profiles.match(read)
      events.onIdentity(read, profile)
    }
    val key = listOf(read.manufacturer, read.model, read.version, read.serial).joinToString("|")
    val held = manager.hasPermission(candidate)
    when (val decision = permissions.decide(key, held, trigger, System.currentTimeMillis())) {
      PermissionPolicy.Decision.Open -> open(manager, candidate)
      PermissionPolicy.Decision.Ask -> askPermission(manager, candidate)
      PermissionPolicy.Decision.Pending -> publish(LinkState.PERMISSION_PENDING, LinkReason.PERMISSION_ASKED)
      PermissionPolicy.Decision.Refused -> publish(LinkState.PERMISSION_DENIED, LinkReason.PERMISSION_REFUSED)
      is PermissionPolicy.Decision.Grace -> {
        publish(LinkState.ACCESSORY_DETECTED, LinkReason.WAITING_FOR_CHOOSER)
        schedule(PermissionPolicy.Trigger.PERIODIC, decision.waitMs)
      }
    }
  }

  private fun askPermission(manager: UsbManager, candidate: UsbAccessory) {
    val intent = Intent(PERMISSION_ACTION).setPackage(context.packageName)
    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Mutable so that the system can add its own result extra to the broadcast
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
    } else {
      PendingIntent.FLAG_UPDATE_CURRENT
    }
    val pending = PendingIntent.getBroadcast(context, 0, intent, flags)
    runCatching { manager.requestPermission(candidate, pending) }
      .onSuccess {
        permissions.onAsked(System.currentTimeMillis())
        publish(LinkState.PERMISSION_PENDING, LinkReason.PERMISSION_ASKED)
      }
      .onFailure {
        permissions.onAskFailed()
        publish(LinkState.PERMISSION_DENIED, LinkReason.PERMISSION_REQUEST_FAILED, it.javaClass.simpleName)
        schedule(PermissionPolicy.Trigger.PERIODIC, RETRY_MS)
      }
  }

  private fun open(manager: UsbManager, candidate: UsbAccessory) {
    val opened = runCatching { manager.openAccessory(candidate) }.getOrNull()
    if (opened == null) {
      // Not a denial on its own: another application may hold the accessory, which is why the page names DJI Fly
      publish(LinkState.PERMISSION_DENIED, LinkReason.OPEN_FAILED)
      schedule(PermissionPolicy.Trigger.PERIODIC, RETRY_AFTER_DISCONNECT_MS)
      return
    }
    cancelAttempts()
    descriptor = opened
    accessory = candidate
    openedAtMs = System.currentTimeMillis()
    firstByteMs = null
    consecutiveProbeFailures = 0
    probesHalted = false
    readsAtLastProbe = 0
    opens += 1
    val streams = object : AccessoryStreams {
      private val fileDescriptor = opened.fileDescriptor
      override val input: InputStream = FileInputStream(fileDescriptor)
      override val output: OutputStream = FileOutputStream(fileDescriptor)
      override fun close() {
        runCatching { input.close() }
        runCatching { output.close() }
        runCatching { opened.close() }
      }
    }
    lateinit var created: AoaTransport
    created = AoaTransport(
      streams = streams,
      onBytes = { data, length ->
        if (firstByteMs == null) {
          firstByteMs = System.currentTimeMillis() - (openedAtMs ?: System.currentTimeMillis())
        }
        events.onBytes(data, length)
      },
      onWrite = { data, isProbe -> events.onWrite(data, isProbe) },
      onEnded = { ended -> handler.post { onTransportEnded(created, ended) } },
    )
    transport = created
    // The parsers restart and the capture marks the open before the first byte can be read, so that a remote that
    // speaks at once is counted in full and never wiped by a reset that comes after it
    events.onOpened()
    // A descriptor is not a DJI connection: the state says only that the accessory is open
    publish(LinkState.ACCESSORY_OPEN, LinkReason.OPENED)
    created.start()
    handler.removeCallbacks(probeTick)
    handler.postDelayed(probeTick, maxOf(FIRST_PROBE_MS, QUIET_AFTER_OPEN_MS))
  }

  private fun runProbe() {
    val current = transport ?: return
    if (!current.isRunning || probesHalted) {
      return
    }
    val queued = probeWorker.submit {
      val result = runCatching { current.probe() }.getOrElse {
        ProbeResult(ok = false, callMs = 0, error = it.javaClass.simpleName)
      }
      handler.post { onProbeResult(current, result) }
    }
    if (!queued) {
      // The page closed between the tick and here
      Log.d(TAG, "probe not run: the probe thread is closed")
    }
  }

  private fun onProbeResult(current: AoaTransport, result: ProbeResult) {
    if (transport !== current) {
      return
    }
    probesSent += 1
    lastProbeCallMs = result.callMs
    val readsNow = current.reads
    val reading = readsNow > readsAtLastProbe
    readsAtLastProbe = readsNow
    events.onProbe(result)
    if (result.ok) {
      consecutiveProbeFailures = 0
      if (state == LinkState.ACCESSORY_OPEN) {
        // The pipe accepts bytes. It does not mean a controller answered, and it never means authority.
        publish(LinkState.LINK_USABLE, LinkReason.PROBE_RETURNS)
      }
      handler.postDelayed(probeTick, PROBE_INTERVAL_MS)
      return
    }
    probeFailures += 1
    consecutiveProbeFailures += 1
    if (result.blocked) {
      // The writer is still inside that call: another probe would only queue behind it. The remote is not reading
      // this endpoint, which is the answer; reads go on, and an unplug still ends the link through its broadcast.
      probesHalted = true
      Log.i(TAG, "a probe write blocked after ${result.callMs} ms; probing stopped on this descriptor")
      publish(state, LinkReason.WRITE_BLOCKED)
      return
    }
    if (consecutiveProbeFailures >= PROBE_FAILURES_TO_DISCONNECT && !reading) {
      closeDescriptor(LinkReason.PROBES_FAILED)
      publish(LinkState.LINK_LOST, LinkReason.PROBES_FAILED)
      schedule(PermissionPolicy.Trigger.PERIODIC, RETRY_AFTER_DISCONNECT_MS)
      return
    }
    handler.postDelayed(probeTick, PROBE_INTERVAL_MS)
  }

  private fun onTransportEnded(ended: AoaTransport, why: LinkReason) {
    // A transport stopped by [closeDescriptor] is already accounted for
    if (transport !== ended) {
      return
    }
    closeDescriptor(why)
    publish(LinkState.LINK_LOST, why)
    schedule(PermissionPolicy.Trigger.PERIODIC, RETRY_AFTER_DISCONNECT_MS)
  }

  private fun closeDescriptor(why: LinkReason) {
    handler.removeCallbacks(probeTick)
    val open = transport != null || descriptor != null
    val current = transport
    transport = null
    current?.stop(why)
    runCatching { descriptor?.close() }
    descriptor = null
    accessory = null
    if (open) {
      events.onClosed(why)
    }
  }

  /** Lets the controller tell the page that frames arrived, which is a claim the transport cannot make */
  fun publish(next: LinkState, why: LinkReason, argument: String? = null) {
    if (next != state || why != reason) {
      Log.i(TAG, "state $next: $why${argument?.let { " ($it)" } ?: ""}")
    }
    state = next
    reason = why
    events.onState(next, why, argument)
  }
}
