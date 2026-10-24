package app.alextran.immich.djilink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Session over cache over seed, kept per accessory strings */
class ParameterSetStoreTest {
  private val preferences = MemoryKeyValueStore()
  private val store = ParameterSetStore(preferences, wallMs = { 1_000L })
  private val remote = AccessoryStrings("DJI", "model-a", "remote", "1.0")
  private val seed = ProfileRegistry.seed20261023!!

  /** The seed with another PPS, so that it is told apart from it */
  private val other = StreamDescription(HevcSamples.VPS, HevcSamples.SPS, byteArrayOf(0x44, 0x01, 0x11, 0x22), seed.info)

  @Test
  fun nothingWithoutASessionACacheOrTheSignature() {
    store.seed = seed
    store.useAccessory(remote)
    assertNull(store.resolve(showsH265Signature = false))
  }

  @Test
  fun theSeedOnlyWithTheH265Signature() {
    store.seed = seed
    store.useAccessory(remote)
    val resolved = store.resolve(showsH265Signature = true)
    assertEquals(DescriptionSource.PROFILE, resolved!!.source)
  }

  @Test
  fun theSessionWinsAndReplacesTheCacheAtOnce() {
    store.seed = seed
    store.useAccessory(remote)
    store.onSessionDescription(other)
    val resolved = store.resolve(showsH265Signature = true)!!
    assertEquals(DescriptionSource.SESSION, resolved.source)
    assertArrayEquals(other.pps, resolved.description.pps)
    assertEquals(1, preferences.size)
    // A new descriptor of the same remote: the session is read again, the cache answers meanwhile
    store.newSession()
    val cached = store.resolve(showsH265Signature = false)!!
    assertEquals(DescriptionSource.CACHE, cached.source)
    assertArrayEquals(other.pps, cached.description.pps)
  }

  @Test
  fun theCacheIsKeptPerAccessoryStrings() {
    store.useAccessory(remote)
    store.onSessionDescription(other)
    store.useAccessory(AccessoryStrings("DJI", "model-b", "remote", "1.0"))
    assertNull(store.cached())
    assertNull(store.resolve(showsH265Signature = false))
    // The cache survives the store, as it survives the page and the app
    val again = ParameterSetStore(preferences)
    again.useAccessory(remote)
    assertNotNull(again.cached())
  }

  @Test
  fun theLastKeyUnitIsKeptPerRemoteWithItsSets() {
    val key = HevcSamples.unitOf(
      HevcSamples.DELIMITER,
      HevcSamples.VPS,
      HevcSamples.SPS,
      HevcSamples.PPS,
      HevcSamples.slice(type = 19),
    )
    store.useAccessory(remote)
    assertNull(store.keptKeyUnit(seed))
    // A P picture is never kept
    store.onKeyUnit(HevcSamples.unitOf(HevcSamples.DELIMITER, HevcSamples.slice()), seed)
    assertNull(store.keptKeyUnit(seed))
    store.onKeyUnit(key, seed)
    val kept = store.keptKeyUnit(seed)!!
    assertArrayEquals(key.bytes, kept.bytes)
    assertEquals(key.nalTypes.toList(), kept.nalTypes.toList())
    // Other sets, another remote, a replay: nothing
    assertNull(store.keptKeyUnit(other))
    val again = ParameterSetStore(preferences)
    again.useAccessory(AccessoryStrings("DJI", "model-b", "remote", "1.0"))
    assertNull(again.keptKeyUnit(seed))
    again.useAccessory(null)
    again.onKeyUnit(key, seed)
    assertNull(again.keptKeyUnit(seed))
    // It survives the store, and goes with the cache
    val later = ParameterSetStore(preferences)
    later.useAccessory(remote)
    assertArrayEquals(key.bytes, later.keptKeyUnit(seed)!!.bytes)
    later.forgetCache()
    assertNull(later.keptKeyUnit(seed))
  }

  @Test
  fun aReplayNeitherReadsNorWritesTheCache() {
    store.useAccessory(null)
    store.onSessionDescription(other)
    assertEquals(0, preferences.size)
    assertEquals(DescriptionSource.SESSION, store.resolve(false)!!.source)
  }

  @Test
  fun aDamagedCacheIsIgnored() {
    store.useAccessory(remote)
    store.onSessionDescription(other)
    preferences.write(ParameterSetStore.KEY_PREFIX + "h265." + remote.key, "something else")
    store.newSession()
    assertNull(store.cached())
  }
}
