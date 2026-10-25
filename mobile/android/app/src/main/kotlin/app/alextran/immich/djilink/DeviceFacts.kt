package app.alextran.immich.djilink

import android.content.Context
import android.hardware.display.DisplayManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The network this device is on, for the exports and Diagnostics (p2/relay-smoothness-2026-10-25.md, 6.1 and 6.2):
 * what the public Android services say, each fact null where they say nothing.
 */
data class NetworkFacts(
  /** wifi, ethernet or other; null when there is no active network */
  val transport: String?,
  val frequencyMhz: Int?,
  val linkMbps: Int?,
  val rssiDbm: Int?,
  /** The Wi-Fi standard as Android names it (802.11n, ac, ax, be), null before Android 11 */
  val standard: String?,
) {
  /** 2.4, 5 or 6 (GHz), from the frequency */
  val band: String? get() = frequencyMhz?.takeIf { it > 0 }?.let { bandOf(it) }

  fun toJson(): JsonObject = buildJsonObject {
    put("transport", transport)
    put("band", band)
    put("frequencyMhz", frequencyMhz)
    put("linkMbps", linkMbps)
    put("rssiDbm", rssiDbm)
    put("standard", standard)
  }

  companion object {
    fun bandOf(frequencyMhz: Int): String = when {
      frequencyMhz < 3_000 -> "2.4"
      frequencyMhz < 5_925 -> "5"
      else -> "6"
    }

    fun standardName(standard: Int): String? = when (standard) {
      1 -> "legacy"
      4 -> "802.11n"
      5 -> "802.11ac"
      6 -> "802.11ax"
      7 -> "802.11ad"
      8 -> "802.11be"
      else -> null
    }

    fun read(context: Context): NetworkFacts {
      val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
      val capabilities = runCatching { connectivity?.getNetworkCapabilities(connectivity.activeNetwork) }.getOrNull()
      val transport = when {
        capabilities == null -> null
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        else -> "other"
      }
      if (transport != "wifi") {
        return NetworkFacts(transport, null, null, null, null)
      }
      val info: WifiInfo? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
          capabilities?.transportInfo as? WifiInfo
        } else {
          null
        }
      }.getOrNull() ?: runCatching {
        @Suppress("DEPRECATION")
        (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager)?.connectionInfo
      }.getOrNull()
      return NetworkFacts(
        transport = transport,
        frequencyMhz = info?.frequency?.takeIf { it > 0 },
        linkMbps = info?.linkSpeed?.takeIf { it > 0 },
        rssiDbm = info?.rssi?.takeIf { it > -127 && it < 0 },
        standard = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          info?.wifiStandard?.let { standardName(it) }
        } else {
          null
        },
      )
    }
  }
}

/**
 * The display of this device and its changes of mode while a reception runs (a TV that switches to 50 Hz shows a 60
 * pictures a second stream with pictures held back), with the facts of the clocks and the collector for the reception
 * record. Started on the main thread; read from any.
 */
class DisplayWatch {
  @Volatile
  private var manager: DisplayManager? = null

  @Volatile
  private var lastRate: Float? = null

  @Volatile
  var changes = 0L
    private set

  private val listener = object : DisplayManager.DisplayListener {
    override fun onDisplayAdded(displayId: Int) = Unit

    override fun onDisplayRemoved(displayId: Int) = Unit

    override fun onDisplayChanged(displayId: Int) {
      if (displayId != Display.DEFAULT_DISPLAY) {
        return
      }
      val rate = display()?.mode?.refreshRate
      if (rate != null && lastRate != null && rate != lastRate) {
        changes += 1
      }
      lastRate = rate
    }
  }

  fun start(context: Context) {
    if (manager != null) {
      return
    }
    val found = context.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: return
    manager = found
    lastRate = display()?.mode?.refreshRate
    runCatching { found.registerDisplayListener(listener, Handler(Looper.getMainLooper())) }
  }

  private fun display(): Display? = runCatching { manager?.getDisplay(Display.DEFAULT_DISPLAY) }.getOrNull()

  private fun runtimeStat(name: String): Long? = runCatching { Debug.getRuntimeStat(name)?.toLongOrNull() }.getOrNull()

  /** The refresh rate now, in Hz */
  val refreshHz: Float? get() = display()?.mode?.refreshRate

  fun toJson(): JsonObject {
    val shown = display()
    val mode = shown?.mode
    return buildJsonObject {
      put("refreshHz", mode?.refreshRate)
      put("modeWidth", mode?.physicalWidth)
      put("modeHeight", mode?.physicalHeight)
      put("modes", shown?.supportedModes?.size)
      put("refreshRates", shown?.supportedModes?.map { it.refreshRate }?.distinct()?.sorted()?.joinToString(" "))
      put("refreshChanges", changes)
      put("elapsedMinusNanoTimeMs", (SystemClock.elapsedRealtimeNanos() - System.nanoTime()) / 1_000_000)
      put("blockingGcCount", runtimeStat("art.gc.blocking-gc-count"))
      put("gcCount", runtimeStat("art.gc.gc-count"))
    }
  }
}
