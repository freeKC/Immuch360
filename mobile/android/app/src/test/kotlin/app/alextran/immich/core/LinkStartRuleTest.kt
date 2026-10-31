package app.alextran.immich.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkStartRuleTest {
  /** The cases Dart reads too (test/domain/services/video_link_rule_test.dart) */
  private val cases: JsonObject by lazy {
    val text = javaClass.classLoader!!.getResourceAsStream("video_link_rule_cases.json")!!.bufferedReader().readText()
    Json.parseToJsonElement(text).jsonObject
  }

  private fun JsonObject.ratio(): Double? = this["ratio"].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.double }

  private fun JsonObject.longOrNull(key: String): Long? =
    this[key].let { if (it == null || it is JsonNull) null else it.jsonPrimitive.long }

  private fun list(name: String): List<JsonObject> = cases[name]!!.jsonArray.map(JsonElement::jsonObject)

  @Test
  fun `the target of every shared case`() {
    for (case in list("target")) {
      val rebuffering = case["rebuffering"]!!.jsonPrimitive.boolean
      assertEquals("$case", case["targetMs"]!!.jsonPrimitive.long, LinkStartRule.targetMs(case.ratio(), rebuffering))
    }
  }

  @Test
  fun `whether it plays, in every shared case`() {
    for (case in list("start")) {
      val started =
        LinkStartRule.shouldStart(
          case["bufferedMs"]!!.jsonPrimitive.long,
          case.ratio(),
          case["rebuffering"]!!.jsonPrimitive.boolean,
          case.longOrNull("minimumHeldMs"),
        )
      assertEquals("$case", case["start"]!!.jsonPrimitive.boolean, started)
    }
  }

  @Test
  fun `the wait that remains, in every shared case`() {
    for (case in list("remaining")) {
      val remaining =
        LinkStartRule.remainingWaitMs(
          case["bufferedMs"]!!.jsonPrimitive.long,
          case.ratio(),
          case["rebuffering"]!!.jsonPrimitive.boolean,
          case.longOrNull("minimumHeldMs"),
        )
      assertEquals("$case", case.longOrNull("remainingMs"), remaining)
    }
  }

  @Test
  fun `dead and slow, in every shared case`() {
    for (case in list("dead")) {
      val dead = LinkStartRule.isDead(case["waiting"]!!.jsonPrimitive.boolean, case.longOrNull("sinceProgressMs"))
      assertEquals("$case", case["dead"]!!.jsonPrimitive.boolean, dead)
    }
    for (case in list("slow")) {
      val slow = LinkStartRule.isSlow(case.ratio(), case["slowForMs"]!!.jsonPrimitive.long)
      assertEquals("$case", case["slow"]!!.jsonPrimitive.boolean, slow)
    }
  }

  @Test
  fun `a link that keeps up starts at one second, as Media3 does, and never waits longer than the caps`() {
    // An 8 Mbit/s film over 12 Mbit/s: it plays as soon as its index and a second are in
    assertEquals(1_000L, LinkStartRule.targetMs(1.5, rebuffering = false))
    // 30 Mbit/s over 2 Mbit/s: the most it waits for, never more than 10 s once a second is there
    assertEquals(15_000L, LinkStartRule.targetMs(0.067, rebuffering = false))
    assertFalse(LinkStartRule.shouldStart(2_000L, 0.067, rebuffering = false, minimumHeldMs = 9_000L))
    assertTrue(LinkStartRule.shouldStart(2_000L, 0.067, rebuffering = false, minimumHeldMs = 10_000L))
  }

  @Test
  fun `a wait is dead only after thirty seconds without progress, never because it is long`() {
    assertFalse(LinkStartRule.isDead(waiting = true, sinceProgressMs = 29_000L))
    assertTrue(LinkStartRule.isDead(waiting = true, sinceProgressMs = 30_000L))
    // Playing from its buffer while the server is silent: not dead
    assertFalse(LinkStartRule.isDead(waiting = false, sinceProgressMs = 60_000L))
  }
}
