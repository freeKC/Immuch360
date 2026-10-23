package app.alextran.immich.djilink

/** Where the stream description a decoder uses came from */
enum class DescriptionSource {
  /** Read from the stream since the descriptor opened */
  SESSION,

  /** The last session description kept for these accessory strings, from an earlier session */
  CACHE,

  /** The seed of the hardware profile: the description of the 23 October 2026 capture */
  PROFILE,
}

data class ResolvedDescription(val description: StreamDescription, val source: DescriptionSource)

/** The four accessory strings a cached description is kept against; the serial is never part of it */
data class AccessoryStrings(
  val manufacturer: String?,
  val model: String?,
  val description: String?,
  val version: String?,
) {
  /** One text key, with a separator no accessory string holds */
  val key: String
    get() = listOf(manufacturer, model, description, version).joinToString("\u001f") { it ?: "" }

  companion object {
    fun of(identity: AccessoryIdentity?): AccessoryStrings? = identity?.let {
      AccessoryStrings(it.manufacturer, it.model, it.description, it.version)
    }
  }
}

/** The app's own preferences, behind an interface so that the store is unit tested in memory */
interface KeyValueStore {
  fun read(key: String): String?
  fun write(key: String, value: String?)
}

class MemoryKeyValueStore : KeyValueStore {
  private val values = mutableMapOf<String, String>()

  override fun read(key: String): String? = values[key]

  override fun write(key: String, value: String?) {
    if (value == null) {
      values.remove(key)
    } else {
      values[key] = value
    }
  }

  val size: Int get() = values.size
}

/**
 * The H.265 stream description a decoder is configured with, in this order:
 *
 * 1. **Session**: the VPS, SPS and PPS read from the stream since the descriptor opened. They always win, and they
 *    replace the cache for these accessory strings at once.
 * 2. **Cache**: the last session description for these accessory strings, kept in the app's own preferences with the
 *    date and the SPS summary. It survives the page and the app.
 * 3. **Seed**: the description the hardware profile carries ([DeviceProfile.streamSeed]), used only when the stream
 *    shows the H.265 signature and there is neither a session description nor a cache.
 *
 * A remote rarely sends a key picture (one in 11 s in the 23 October capture), so a decoder that waited for the
 * stream's own parameter sets could wait a long time; with a description in hand it starts at once and the picture
 * builds up. A wrong seed only costs decoder errors until the stream's own description arrives, and the page names the
 * source in use.
 */
class ParameterSetStore(
  private val preferences: KeyValueStore,
  private val wallMs: () -> Long = { System.currentTimeMillis() },
) {
  companion object {
    const val KEY_PREFIX = "djilink.streamDescription."
    private const val FORMAT = "h265-v1"
    private const val SEPARATOR = "|"
  }

  /** The accessory the stream comes from; null for a replay, which neither reads nor writes the cache */
  var accessory: AccessoryStrings? = null
    private set

  /** The seed of the profile in use, if it carries one */
  var seed: StreamDescription? = null

  private var session: StreamDescription? = null

  /**
   * Where the session description came from on the phone, for a stream relayed by a phone: the phone resolved its
   * description (from its session, its cache or the seed) and sent it with its source. Null for a description read
   * from the stream itself.
   */
  private var relayedSource: DescriptionSource? = null

  /** The descriptor changed: a new accessory, or none for a replay. The session description goes with the old one. */
  fun useAccessory(strings: AccessoryStrings?) {
    accessory = strings
    session = null
    relayedSource = null
  }

  /** A new descriptor of the same accessory: the session description must be read from the stream again */
  fun newSession() {
    session = null
    relayedSource = null
  }

  /**
   * The description a phone relays with its parameter sets, and where the phone had it from. For a relayed stream the
   * store has no accessory (no cache is read or written) and no seed: the phone resolved those and sent the result.
   */
  fun onRelayedDescription(description: StreamDescription, source: DescriptionSource) {
    session = description
    relayedSource = source
  }

  /** The stream gave its own description: it wins, and it becomes the cache of these accessory strings */
  fun onSessionDescription(description: StreamDescription) {
    session = description
    relayedSource = null
    val strings = accessory ?: return
    // One line of text: the three sets in hexadecimal, the date and the SPS summary, separated by a character that
    // neither hexadecimal nor the summary holds (no JSON library is needed by the JVM tests this way)
    val summary = "${description.info.profileName} ${if (description.info.highTier) "High" else "Main"} tier " +
      "level ${description.info.levelName} ${description.info.width}x${description.info.height}"
    val record = listOf(
      FORMAT,
      StreamDescription.hex(description.vps),
      StreamDescription.hex(description.sps),
      StreamDescription.hex(description.pps),
      wallMs().toString(),
      summary,
    ).joinToString(SEPARATOR)
    preferences.write(cacheKey(strings), record)
  }

  /** The description to configure a decoder with now, or null when there is none to be had */
  fun resolve(showsH265Signature: Boolean): ResolvedDescription? {
    session?.let { return ResolvedDescription(it, relayedSource ?: DescriptionSource.SESSION) }
    cached()?.let { return ResolvedDescription(it, DescriptionSource.CACHE) }
    val seeded = seed
    if (seeded != null && showsH265Signature) {
      return ResolvedDescription(seeded, DescriptionSource.PROFILE)
    }
    return null
  }

  /** The cached description of the current accessory strings, null when there is none or it no longer parses */
  fun cached(): StreamDescription? {
    val strings = accessory ?: return null
    val text = preferences.read(cacheKey(strings)) ?: return null
    val cells = text.split(SEPARATOR)
    if (cells.size < 4 || cells[0] != FORMAT) {
      return null
    }
    return StreamDescription.fromHex(cells[1], cells[2], cells[3])
  }

  fun forgetCache() {
    val strings = accessory ?: return
    preferences.write(cacheKey(strings), null)
  }

  private fun cacheKey(strings: AccessoryStrings): String = KEY_PREFIX + "h265." + strings.key
}
