package app.alextran.immich.djilink

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** What the phone says of its link in each telemetry record: where its picture comes from and how the link stands */
data class RelayLinkFacts(
  /** cable, replay or none */
  val source: String,
  /** The state of the link, as the page names it (videoReady, aircraftLinked ...) */
  val state: String,
  val aircraft: Boolean,
  val remote: Boolean,
  val replayName: String? = null,
  val replayPositionMs: Long? = null,
  /** h265, h264 or unknown */
  val codec: String = "unknown",
)

/** The phone's own video numbers, so that the headset can say how far behind the phone's screen it is */
data class RelayPhoneVideo(
  val picturesPerSecond: Double,
  val megabitsPerSecond: Double,
  val inProcessMedianMs: Double?,
  val decodeMedianMs: Double?,
  val decodeP95Ms: Double?,
  val lostPictures: Long,
  val encoderRestarts: Long,
  val keyPictureAgoMs: Long?,
) {
  companion object {
    fun of(stats: VideoStats): RelayPhoneVideo = RelayPhoneVideo(
      picturesPerSecond = stats.picturesPerSecond,
      megabitsPerSecond = stats.megabitsPerSecond,
      inProcessMedianMs = stats.inProcessMedianMs,
      decodeMedianMs = stats.decodeMedianMs,
      decodeP95Ms = stats.decodeP95Ms,
      lostPictures = stats.lostPictures,
      encoderRestarts = stats.encoderRestarts,
      keyPictureAgoMs = stats.keyPictureAgoMs,
    )
  }
}

/**
 * The phone's choices for the obstacle ring (p2/design-obstacle-ring-2026-10-25.md, 5.4): whether it is offered,
 * "Glow from", "Strong glow from" and whether the side is drawn. The pilot sets them once on the phone, and a TV or a
 * headset draws the ring the phone draws; each keeps its own sound, number and sample.
 */
data class RelayObstacleRing(
  val offered: Boolean,
  val farM: Double,
  val nearM: Double,
  val directional: Boolean,
) {
  fun settings(): RingSettings = RingSettings(farM, nearM, directional).clamped()
}

/** One TELEMETRY record as the headset read it */
data class RelayTelemetryRecord(
  /** The phone's clock when it was built */
  val phoneNs: Long,
  val sequence: Long,
  val link: RelayLinkFacts,
  /** The values with the ages they had on the phone */
  val values: TelemetryValues,
  val phoneVideo: RelayPhoneVideo?,
  val headsets: Int,
  val unitsDropped: Long,
  /** Null from a phone of an earlier build: no ring is drawn from its record */
  val obstacleRing: RelayObstacleRing? = null,
) {
  /**
   * The values [sinceMs] after the record arrived: each age grows by that much, and a group the phone no longer
   * refreshes turns stale here too, never before the phone's own bound.
   */
  fun aged(sinceMs: Long): TelemetryValues {
    val since = sinceMs.coerceAtLeast(0)
    fun <T> Timed<T>?.older(): Timed<T>? = this?.copy(
      ageMs = ageMs + since,
      stale = stale || since > TelemetryDecoder.MIN_STALE_MS,
    )
    return values.copy(
      flight = values.flight.older(),
      gimbal = values.gimbal.older(),
      battery = values.battery.older(),
      remoteBatteryPercent = values.remoteBatteryPercent.older(),
      signalBars = values.signalBars.older(),
      rangeBelow = values.rangeBelow.older(),
      obstacles = values.obstacles.older(),
      link = values.link.copy(
        signalAircraftSide = values.link.signalAircraftSide.older(),
        signalRemoteSide = values.link.signalRemoteSide.older(),
        liveRateMbps = values.link.liveRateMbps.older(),
        aircraftClockMs = values.link.aircraftClockMs.older(),
      ),
    )
  }
}

/**
 * The TELEMETRY record of p2/design-stage2b.md, 4.7: our own names, those of the page's model of stage 2, with each
 * group's age, staleness and evidence. It never carries a position (stage 2 never decodes it), a serial number, a
 * module record or the accessory strings. The fields of the second telemetry reading (the vertical and horizontal
 * speeds, the signal bars, the distance below, the nearest obstacle) are additive: a headset of an earlier build
 * ignores them, and a record of an earlier phone reads as before, without them. So are the 72 sectors of the obstacle
 * ring and the phone's choices for it (p2/design-obstacle-ring-2026-10-25.md, 5.4). Built once per tick on the phone and
 * queued to every headset; read back on the headset into the same [TelemetryValues] the phone's decoder gives, so that
 * the flight section draws it unchanged.
 * Written and read with the JSON element API of kotlinx.serialization, which the JVM unit tests can run.
 */
object RelayTelemetry {
  const val EVIDENCE_PUBLIC_AND_CAPTURE = "publicAndCapture"
  const val EVIDENCE_CAPTURE = "capture"
  const val EVIDENCE_CANDIDATE = "candidate"

  fun build(
    phoneNs: Long,
    sequence: Long,
    link: RelayLinkFacts,
    values: TelemetryValues?,
    phoneVideo: RelayPhoneVideo?,
    headsets: Int,
    unitsDropped: Long,
    ring: RelayObstacleRing? = null,
  ): JsonObject = buildJsonObject {
    put("t", phoneNs)
    put("seq", sequence)
    put(
      "link",
      buildJsonObject {
        put("source", link.source)
        put("state", link.state)
        put("aircraft", link.aircraft)
        put("remote", link.remote)
        put("replayName", link.replayName)
        put("replayPositionMs", link.replayPositionMs)
        put("codec", link.codec)
      },
    )
    if (values != null) {
      put("layoutMismatches", values.layoutMismatches)
      values.flight?.let { timed ->
        val reading = timed.value
        put(
          "flight",
          buildJsonObject {
            age(timed)
            put("heightM", reading.heightM)
            put("speedsMps", numbers(reading.speedsMps))
            put("pitchDeg", reading.pitchDeg)
            put("rollDeg", reading.rollDeg)
            put("headingDeg", reading.headingDeg)
            put("mode", reading.mode)
            put("inAir", reading.inAir)
            put("motorsOn", reading.motorsOn)
            put("motorTimeS", reading.motorTimeS)
            put("satellites", reading.satellites)
            put("groundHeightM", reading.groundHeightM)
            put("verticalSpeedMps", reading.verticalSpeedMps)
            put("horizontalSpeedMps", reading.horizontalSpeedMps)
            // The phone's HeightHold, so that a TV and a headset hold the height back when the phone does
            put("heightHeld", reading.heightHeld)
            put("evidence", EVIDENCE_PUBLIC_AND_CAPTURE)
          },
        )
      }
      values.gimbal?.let { timed ->
        val reading = timed.value
        put(
          "gimbal",
          buildJsonObject {
            age(timed)
            put("headingDeg", reading.headingDeg)
            put("clockMs", reading.clockMs)
            put("headingFineDeg", reading.headingFineDeg)
            put("angle1Deg", reading.angle1Deg)
            put("angle2Deg", reading.angle2Deg)
            put("quaternion", numbers(reading.quaternion))
            put("evidence", EVIDENCE_CAPTURE)
          },
        )
      }
      values.battery?.let { timed ->
        val reading = timed.value
        put(
          "battery",
          buildJsonObject {
            age(timed)
            put("percent", reading.percent)
            put("volts", reading.voltageV)
            put("amps", reading.currentA)
            put("remainingMah", reading.remainingMah)
            put("fullMah", reading.fullMah)
            put("temperatureC", reading.temperatureC)
            put("cells", reading.cells)
            put("status", "%016x".format(reading.status))
            put("evidence", EVIDENCE_PUBLIC_AND_CAPTURE)
          },
        )
      }
      values.remoteBatteryPercent?.let { timed ->
        put(
          "remoteBattery",
          buildJsonObject {
            put("percent", timed.value)
            age(timed)
            put("evidence", EVIDENCE_CANDIDATE)
          },
        )
      }
      values.signalBars?.let { timed ->
        put(
          "signalBars",
          buildJsonObject {
            put("bars", timed.value)
            age(timed)
            put("evidence", EVIDENCE_CANDIDATE)
          },
        )
      }
      values.rangeBelow?.let { timed ->
        put(
          "rangeBelow",
          buildJsonObject {
            put("distanceM", timed.value.distanceM)
            age(timed)
            put("evidence", EVIDENCE_CANDIDATE)
          },
        )
      }
      values.obstacles?.let { timed ->
        put(
          "obstacles",
          buildJsonObject {
            put("nearestM", timed.value.nearestM)
            put("nearestIndex", timed.value.nearestIndex)
            put("noReading", timed.value.noReading)
            timed.value.sectorsMm?.let { sectors ->
              put("sectorsMm", buildJsonArray { sectors.forEach { add(if (it == null) JsonNull else JsonPrimitive(it)) } })
            }
            age(timed)
            put("evidence", EVIDENCE_CANDIDATE)
          },
        )
      }
      val radio = values.link
      val clock = radio.aircraftClockMs
      put(
        "radio",
        buildJsonObject {
          timedField("signalAircraftSide", radio.signalAircraftSide)
          timedField("signalRemoteSide", radio.signalRemoteSide)
          timedField("liveRateMbps", radio.liveRateMbps)
          put("aircraftClockMs", clock?.value)
          put("clockJitterP95Ms", radio.clockJitterP95Ms)
          put("clockDriftMs", radio.clockDriftMs)
          put("ageMs", clock?.ageMs)
          put("stale", clock?.stale ?: false)
        },
      )
    }
    if (phoneVideo != null) {
      put(
        "phoneVideo",
        buildJsonObject {
          put("picturesPerSecond", phoneVideo.picturesPerSecond)
          put("megabitsPerSecond", phoneVideo.megabitsPerSecond)
          put("inProcessMedianMs", phoneVideo.inProcessMedianMs)
          put("decodeMedianMs", phoneVideo.decodeMedianMs)
          put("decodeP95Ms", phoneVideo.decodeP95Ms)
          put("lostPictures", phoneVideo.lostPictures)
          put("encoderRestarts", phoneVideo.encoderRestarts)
          put("keyPictureAgoMs", phoneVideo.keyPictureAgoMs)
        },
      )
    }
    put(
      "relay",
      buildJsonObject {
        put("headsets", headsets)
        put("unitsDropped", unitsDropped)
      },
    )
    if (ring != null) {
      put(
        "obstacleRing",
        buildJsonObject {
          put("offered", ring.offered)
          put("farM", ring.farM)
          put("nearM", ring.nearM)
          put("directional", ring.directional)
        },
      )
    }
  }

  /** A record read back, null when it is not one; unknown keys are ignored, missing groups are absent */
  fun parse(json: JsonObject?): RelayTelemetryRecord? {
    if (json == null) {
      return null
    }
    return runCatching {
      val link = json.obj("link")
      val radio = json.obj("radio")
      val radioAge = radio?.long("ageMs") ?: 0L
      val radioStale = radio?.bool("stale") ?: false
      RelayTelemetryRecord(
        phoneNs = json.long("t") ?: 0L,
        sequence = json.long("seq") ?: 0L,
        link = RelayLinkFacts(
          source = link?.string("source") ?: "none",
          state = link?.string("state") ?: "absent",
          aircraft = link?.bool("aircraft") ?: false,
          remote = link?.bool("remote") ?: false,
          replayName = link?.string("replayName"),
          replayPositionMs = link?.long("replayPositionMs"),
          codec = link?.string("codec") ?: "unknown",
        ),
        values = TelemetryValues(
          flight = json.obj("flight")?.let { flight ->
            timed(
              flight,
              FlightReading(
                heightM = flight.double("heightM") ?: 0.0,
                speedsMps = flight.doubles("speedsMps"),
                pitchDeg = flight.double("pitchDeg") ?: 0.0,
                rollDeg = flight.double("rollDeg") ?: 0.0,
                headingDeg = flight.double("headingDeg") ?: 0.0,
                mode = (flight.long("mode") ?: 0L).toInt(),
                inAir = flight.bool("inAir") ?: false,
                motorsOn = flight.bool("motorsOn") ?: false,
                satellites = (flight.long("satellites") ?: 0L).toInt(),
                groundHeightM = flight.double("groundHeightM") ?: 0.0,
                motorTimeS = flight.double("motorTimeS") ?: 0.0,
                flags = 0L,
                verticalSpeedMps = flight.double("verticalSpeedMps") ?: 0.0,
                horizontalSpeedMps = flight.double("horizontalSpeedMps") ?: 0.0,
                // A phone of an earlier build holds nothing back
                heightHeld = flight.bool("heightHeld") ?: false,
              ),
            )
          },
          gimbal = json.obj("gimbal")?.let { gimbal ->
            timed(
              gimbal,
              GimbalReading(
                headingDeg = gimbal.double("headingDeg") ?: 0.0,
                clockMs = gimbal.long("clockMs") ?: 0L,
                headingFineDeg = gimbal.double("headingFineDeg") ?: 0.0,
                angle1Deg = gimbal.double("angle1Deg") ?: 0.0,
                angle2Deg = gimbal.double("angle2Deg") ?: 0.0,
                quaternion = gimbal.doubles("quaternion"),
              ),
            )
          },
          battery = json.obj("battery")?.let { battery ->
            timed(
              battery,
              BatteryReading(
                voltageV = battery.double("volts") ?: 0.0,
                currentA = battery.double("amps") ?: 0.0,
                fullMah = battery.long("fullMah") ?: 0L,
                remainingMah = battery.long("remainingMah") ?: 0L,
                temperatureC = battery.double("temperatureC") ?: 0.0,
                cells = (battery.long("cells") ?: 0L).toInt(),
                percent = (battery.long("percent") ?: 0L).toInt(),
                status = battery.string("status")?.let { java.lang.Long.parseUnsignedLong(it, 16) } ?: 0L,
              ),
            )
          },
          remoteBatteryPercent = json.obj("remoteBattery")?.let { remote ->
            remote.long("percent")?.let { timed(remote, it.toInt()) }
          },
          link = LinkReadings(
            signalAircraftSide = radio?.long("signalAircraftSide")?.let {
              Timed(it.toInt(), radio.ageOf("signalAircraftSide", radioAge), radio.staleOf("signalAircraftSide", radioStale))
            },
            signalRemoteSide = radio?.long("signalRemoteSide")?.let {
              Timed(it.toInt(), radio.ageOf("signalRemoteSide", radioAge), radio.staleOf("signalRemoteSide", radioStale))
            },
            liveRateMbps = radio?.double("liveRateMbps")?.let {
              Timed(it, radio.ageOf("liveRateMbps", radioAge), radio.staleOf("liveRateMbps", radioStale))
            },
            aircraftClockMs = radio?.long("aircraftClockMs")?.let { Timed(it, radioAge, radioStale) },
            clockJitterP95Ms = radio?.double("clockJitterP95Ms"),
            clockDriftMs = radio?.double("clockDriftMs"),
          ),
          layoutMismatches = json.long("layoutMismatches") ?: 0L,
          decoded = emptyMap(),
          signalBars = json.obj("signalBars")?.let { bars -> bars.long("bars")?.let { timed(bars, it.toInt()) } },
          rangeBelow = json.obj("rangeBelow")?.let { range ->
            timed(range, RangeBelowReading(range.double("distanceM")))
          },
          obstacles = json.obj("obstacles")?.let { ring ->
            timed(
              ring,
              ObstacleReading(
                nearestM = ring.double("nearestM"),
                nearestIndex = ring.long("nearestIndex")?.toInt(),
                noReading = (ring.long("noReading") ?: 0L).toInt(),
                sectorsMm = ring.sectors("sectorsMm"),
              ),
            )
          },
        ),
        phoneVideo = json.obj("phoneVideo")?.let { video ->
          RelayPhoneVideo(
            picturesPerSecond = video.double("picturesPerSecond") ?: 0.0,
            megabitsPerSecond = video.double("megabitsPerSecond") ?: 0.0,
            inProcessMedianMs = video.double("inProcessMedianMs"),
            decodeMedianMs = video.double("decodeMedianMs"),
            decodeP95Ms = video.double("decodeP95Ms"),
            lostPictures = video.long("lostPictures") ?: 0L,
            encoderRestarts = video.long("encoderRestarts") ?: 0L,
            keyPictureAgoMs = video.long("keyPictureAgoMs"),
          )
        },
        headsets = (json.obj("relay")?.long("headsets") ?: 0L).toInt(),
        unitsDropped = json.obj("relay")?.long("unitsDropped") ?: 0L,
        obstacleRing = json.obj("obstacleRing")?.let { ring ->
          RelayObstacleRing(
            offered = ring.bool("offered") ?: false,
            farM = ring.double("farM") ?: RingSettings.DEFAULT_FAR_M,
            nearM = ring.double("nearM") ?: RingSettings.DEFAULT_NEAR_M,
            directional = ring.bool("directional") ?: false,
          )
        },
      )
    }.getOrNull()
  }

  /** The page's name of a link state: VIDEO_READY reads videoReady */
  fun stateName(state: LinkState): String =
    state.name.lowercase().split('_').mapIndexed { index, part ->
      if (index == 0) part else part.replaceFirstChar { it.uppercase() }
    }.joinToString("")

  private fun kotlinx.serialization.json.JsonObjectBuilder.age(timed: Timed<*>) {
    put("ageMs", timed.ageMs)
    put("stale", timed.stale)
  }

  private fun kotlinx.serialization.json.JsonObjectBuilder.timedField(name: String, timed: Timed<out Number>?) {
    if (timed == null) {
      put(name, JsonNull)
      return
    }
    put(name, JsonPrimitive(timed.value))
    put("${name}AgeMs", timed.ageMs)
    put("${name}Stale", timed.stale)
  }

  private fun numbers(values: List<Double>): JsonArray = buildJsonArray { values.forEach { add(JsonPrimitive(it)) } }

  private fun <T> timed(group: JsonObject, value: T): Timed<T> =
    Timed(value, group.long("ageMs") ?: 0L, group.bool("stale") ?: false)

  private fun JsonObject.element(name: String): JsonElement? = this[name]?.takeIf { it !is JsonNull }

  private fun JsonObject.ageOf(name: String, fallback: Long): Long = long("${name}AgeMs") ?: fallback

  private fun JsonObject.staleOf(name: String, fallback: Boolean): Boolean = bool("${name}Stale") ?: fallback

  private fun JsonObject.obj(name: String): JsonObject? = element(name)?.let { it as? JsonObject }

  private fun JsonObject.long(name: String): Long? =
    element(name)?.jsonPrimitive?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }

  private fun JsonObject.double(name: String): Double? = element(name)?.jsonPrimitive?.doubleOrNull

  private fun JsonObject.bool(name: String): Boolean? = element(name)?.jsonPrimitive?.booleanOrNull

  private fun JsonObject.string(name: String): String? = element(name)?.jsonPrimitive?.takeIf { it.isString }?.content

  private fun JsonObject.doubles(name: String): List<Double> =
    element(name)?.jsonArray?.mapNotNull { it.jsonPrimitive.doubleOrNull } ?: emptyList()

  /** The 72 sectors in millimetres, null for one with no reading; null when absent or of another count */
  private fun JsonObject.sectors(name: String): List<Int?>? =
    element(name)?.jsonArray
      ?.map { (it as? JsonPrimitive)?.longOrNull?.toInt() }
      ?.takeIf { it.size == ObstacleRing.SECTORS }
}

/** Reads a TELEMETRY body; null when it is not JSON or not a record */
fun RelayTelemetry.parseBody(body: ByteArray): RelayTelemetryRecord? = parse(RelayWire.parseJson(body))
