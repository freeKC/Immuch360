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
import java.util.concurrent.Executors

/**
 * The platform side of the link: the broadcasts, the accessory list, the permission, the open, the liveness probe and
 * the retries.
 *
 * The timings are the ones the DJI controller application uses (p2/protocol.md, section 8), because they are the only
 * known good ones for this hardware, and every one of them is a named constant here so that a capture can change one
 * without touching the logic.
 *
 * Three things differ from that application on purpose. The whole accessory list is looked at, not only its first
 * entry, so that a device nobody has described still reaches the page. The permission action belongs to this
 * application, never to DJI, and the result is checked with [UsbManager.hasPermission] rather than trusted from the
 * broadcast extra. And nothing is written for the first [QUIET_AFTER_OPEN_MS] after an open, so that the question
 * "does the remote speak first" has a clean answer on the page.
 */
interface LinkEvents {
  fun onState(state: LinkState, detail: String?)
  fun onIdentity(identity: AccessoryIdentity?, profile: DeviceProfile?)
  fun onBytes(data: ByteArray, length: Int)
  fun onWrite(data: ByteArray, isProbe: Boolean)
  fun onProbe(result: ProbeResult)
}

class AoaAccessoryManager(
  private val context: Context,
  private val events: LinkEvents,
  private val profiles: ProfileRegistry = ProfileRegistry(),
  private val handler: Handler = Handler(Looper.getMainLooper()),
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

    /** The sixth failure in a row declares a disconnect; five are tolerated */
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
  private var permissionAskedFor: String? = null

  var transport: AoaTransport? = null
    private set
  var state: LinkState = LinkState.ABSENT
    private set
  var identity: AccessoryIdentity? = null
    private set
  var profile: DeviceProfile? = null
    private set
  var attempts = 0L
    private set
  var probesSent = 0L
    private set
  var probeFailures = 0L
    private set
  var consecutiveProbeFailures = 0
    private set
  var lastProbeCallMs = 0L
    private set
  var openedAtMs: Long? = null
    private set
  var firstByteMs: Long? = null
    private set

  private val attempt = Runnable { connectIfPossible() }
  private val probeTick = Runnable { runProbe() }

  /** Starts looking. Does nothing to the aircraft and sends nothing until the quiet window has passed. */
  fun start() {
    if (receiver != null) {
      return
    }
    val filter = IntentFilter().apply {
      addAction(PERMISSION_ACTION)
      addAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
      addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
      addAction(UsbEnvironment.USB_STATE_ACTION)
    }
    val created = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) = onBroadcast(intent)
    }
    receiver = created
    ContextCompat.registerReceiver(context, created, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    val environment = UsbEnvironment.read(context)
    if (!environment.transportPossible) {
      publish(
        LinkState.UNSUPPORTED_TRANSPORT,
        "this device declares no USB accessory feature and has no accessory device node",
      )
      return
    }
    publish(LinkState.ABSENT, "looking for an accessory")
    handler.postDelayed(attempt, FIRST_ATTEMPT_MS)
  }

  fun stop() {
    handler.removeCallbacks(attempt)
    handler.removeCallbacks(probeTick)
    receiver?.let { runCatching { context.unregisterReceiver(it) } }
    receiver = null
    closeDescriptor("the page was closed")
    probeThread.shutdownNow()
  }

  /** The pilot asked for another go without unplugging anything */
  fun retryNow() {
    handler.removeCallbacks(attempt)
    handler.post(attempt)
  }

  private fun onBroadcast(intent: Intent) {
    when (intent.action) {
      UsbEnvironment.USB_STATE_ACTION -> {
        val now = System.currentTimeMillis()
        if (now - lastUsbStateMs < USB_STATE_DEBOUNCE_MS) {
          return
        }
        lastUsbStateMs = now
        retryNow()
      }
      UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
        closeDescriptor("the accessory was detached")
        publish(LinkState.ABSENT, "the accessory was detached")
        handler.removeCallbacks(attempt)
        handler.postDelayed(attempt, RETRY_AFTER_DISCONNECT_MS)
      }
      UsbManager.ACTION_USB_ACCESSORY_ATTACHED, PERMISSION_ACTION -> retryNow()
      else -> Unit
    }
  }

  private fun connectIfPossible() {
    if (receiver == null || transport?.isRunning == true) {
      return
    }
    attempts += 1
    val manager = usb
    if (manager == null) {
      publish(LinkState.UNSUPPORTED_TRANSPORT, "this device has no USB service")
      return
    }
    // Documented to hold at most one entry; every entry is looked at and logged anyway
    val list = runCatching { manager.accessoryList?.toList() ?: emptyList() }.getOrDefault(emptyList())
    if (list.isEmpty()) {
      publish(LinkState.ABSENT, "no accessory is listed")
      handler.postDelayed(attempt, RETRY_MS)
      return
    }
    for (candidate in list) {
      Log.i(
        TAG,
        "accessory listed: manufacturer=${candidate.manufacturer} model=${candidate.model} " +
          "description=${candidate.description} version=${candidate.version}",
      )
    }
    // The platform documents at most one entry, and the reference application only ever reads the first. The whole
    // list is read here, and a DJI accessory anywhere in it is preferred over whatever came first, so that a device
    // that does list more than one still reaches the right end of the cable.
    val candidate = list.firstOrNull { it.manufacturer.equals(ProfileRegistry.MANUFACTURER, ignoreCase = true) }
      ?: list.first()
    val read = AccessoryIdentity(
      manufacturer = candidate.manufacturer,
      model = candidate.model,
      description = candidate.description,
      version = candidate.version,
      serial = runCatching { candidate.serial }.getOrNull(),
      uri = candidate.uri,
    )
    identity = read
    profile = profiles.match(read)
    events.onIdentity(read, profile)
    publish(LinkState.ACCESSORY_DETECTED, "an accessory is listed")
    if (!manager.hasPermission(candidate)) {
      askPermission(manager, candidate)
      return
    }
    open(manager, candidate)
  }

  private fun askPermission(manager: UsbManager, candidate: UsbAccessory) {
    val key = candidate.toString()
    if (permissionAskedFor == key && state == LinkState.PERMISSION_PENDING) {
      return
    }
    permissionAskedFor = key
    publish(LinkState.PERMISSION_PENDING, "waiting for the USB permission")
    val intent = Intent(PERMISSION_ACTION).setPackage(context.packageName)
    val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Mutable so that the system can add its own result extra to the broadcast
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
    } else {
      PendingIntent.FLAG_UPDATE_CURRENT
    }
    val pending = PendingIntent.getBroadcast(context, 0, intent, flags)
    runCatching { manager.requestPermission(candidate, pending) }.onFailure {
      publish(LinkState.PERMISSION_DENIED, "the permission could not be asked for: ${it.javaClass.simpleName}")
      handler.postDelayed(attempt, RETRY_MS)
    }
  }

  private fun open(manager: UsbManager, candidate: UsbAccessory) {
    val opened = runCatching { manager.openAccessory(candidate) }.getOrNull()
    if (opened == null) {
      // Not a denial on its own: another application may hold the accessory, which is why the page names DJI Fly
      publish(LinkState.PERMISSION_DENIED, "the accessory did not open; another application may hold it")
      handler.postDelayed(attempt, RETRY_AFTER_DISCONNECT_MS)
      return
    }
    descriptor = opened
    accessory = candidate
    openedAtMs = System.currentTimeMillis()
    firstByteMs = null
    consecutiveProbeFailures = 0
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
    val created = AoaTransport(
      streams = streams,
      onBytes = { data, length ->
        if (firstByteMs == null) {
          firstByteMs = System.currentTimeMillis() - (openedAtMs ?: System.currentTimeMillis())
        }
        events.onBytes(data, length)
      },
      onWrite = { data, isProbe -> events.onWrite(data, isProbe) },
      onEnded = { reason -> onTransportEnded(reason) },
    )
    transport = created
    created.start()
    // A descriptor is not a DJI connection: the state says only that the accessory is open
    publish(LinkState.ACCESSORY_OPEN, "the accessory is open; nothing has been written")
    handler.removeCallbacks(probeTick)
    handler.postDelayed(probeTick, maxOf(FIRST_PROBE_MS, QUIET_AFTER_OPEN_MS))
  }

  /**
   * The probe is one blocking call on purpose, and its duration is the measurement, so it never runs on the main
   * thread: it goes to this one thread and the answer comes back to the handler.
   */
  private val probeThread = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "DjiLinkProbe").apply { isDaemon = true }
  }

  private fun runProbe() {
    val current = transport ?: return
    if (!current.isRunning) {
      return
    }
    probeThread.execute {
      val result = current.probe()
      handler.post { onProbeResult(current, result) }
    }
  }

  private fun onProbeResult(current: AoaTransport, result: ProbeResult) {
    if (transport !== current) {
      return
    }
    probesSent += 1
    lastProbeCallMs = result.callMs
    events.onProbe(result)
    if (result.ok) {
      consecutiveProbeFailures = 0
      if (state == LinkState.ACCESSORY_OPEN) {
        // The pipe accepts bytes. It does not mean a controller answered, and it never means authority.
        publish(LinkState.LINK_USABLE, "the liveness probe returns; nothing has answered yet")
      }
    } else {
      probeFailures += 1
      consecutiveProbeFailures += 1
      if (consecutiveProbeFailures >= PROBE_FAILURES_TO_DISCONNECT) {
        closeDescriptor("$PROBE_FAILURES_TO_DISCONNECT liveness probes in a row failed")
        publish(LinkState.LINK_LOST, "$PROBE_FAILURES_TO_DISCONNECT liveness probes in a row failed")
        handler.postDelayed(attempt, RETRY_AFTER_DISCONNECT_MS)
        return
      }
    }
    handler.postDelayed(probeTick, PROBE_INTERVAL_MS)
  }

  private fun onTransportEnded(reason: String) {
    handler.post {
      handler.removeCallbacks(probeTick)
      descriptor = null
      accessory = null
      publish(LinkState.LINK_LOST, reason)
      handler.postDelayed(attempt, RETRY_AFTER_DISCONNECT_MS)
    }
  }

  private fun closeDescriptor(reason: String) {
    handler.removeCallbacks(probeTick)
    transport?.stop(reason)
    transport = null
    runCatching { descriptor?.close() }
    descriptor = null
    accessory = null
  }

  /** Lets the controller tell the page that frames arrived, which is a claim the transport cannot make */
  fun publish(next: LinkState, detail: String?) {
    state = next
    events.onState(next, detail)
  }
}
