package app.alextran.immich.immersive.splat

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The life of the splat entity (lot S5): shown at its load event, destroyed at once when shown, only after its load
 * when dropped while loading, one splat at a time, and no call at all on the SDK once its scene is down.
 */
class SplatSessionTest {
  private class Entity(val name: String) {
    override fun toString() = name
  }

  private val calls = mutableListOf<String>()
  private val session =
    SplatSession(
      object : SplatSession.Effects<Entity> {
        override fun destroy(handle: Entity) {
          calls += "destroy $handle"
        }

        override fun show(handle: Entity) {
          calls += "show $handle"
        }
      }
    )

  private fun open(name: String): Entity {
    val entity = Entity(name)
    assertTrue(session.prepare())
    var made = false
    session.whenFree { made = session.made(entity) }
    assertTrue(made)
    return entity
  }

  @Test
  fun `a splat shows at its load event, and goes at once once shown`() {
    val a = open("a")
    assertEquals(SplatSession.State.LOADING, session.state)
    assertEquals(SplatSession.Loaded.SHOWN, session.loaded(a, success = true))
    assertEquals(SplatSession.State.SHOWN, session.state)
    session.drop()
    assertEquals(listOf("show a", "destroy a"), calls)
    assertNull(session.handle)
    assertEquals(SplatSession.State.IDLE, session.state)
  }

  @Test
  fun `a load that fails takes its entity away`() {
    val a = open("a")
    assertEquals(SplatSession.Loaded.FAILED, session.loaded(a, success = false))
    assertEquals(SplatSession.State.FAILED, session.state)
    assertEquals(listOf("destroy a"), calls)
    // Its drop then has nothing left to do
    session.drop()
    assertEquals(listOf("destroy a"), calls)
  }

  @Test
  fun `a splat dropped while it loads goes only at its load event, and the next one waits for it`() {
    val a = open("a")
    session.drop()
    assertEquals(emptyList<String>(), calls)
    // The next splat is read meanwhile, but its entity waits
    val b = Entity("b")
    assertTrue(session.prepare())
    var started = false
    session.whenFree {
      started = true
      session.made(b)
    }
    assertFalse(started)
    assertEquals(SplatSession.Loaded.DROPPED, session.loaded(a, success = true))
    assertTrue(started)
    assertEquals(listOf("destroy a"), calls)
    assertEquals(SplatSession.Loaded.SHOWN, session.loaded(b, success = true))
    assertEquals(listOf("destroy a", "show b"), calls)
  }

  @Test
  fun `a load that never ends is given up`() {
    val a = open("a")
    assertEquals(SplatSession.Loaded.FAILED, session.timedOut(a))
    assertEquals(listOf("destroy a"), calls)
    val b = open("b")
    session.drop()
    assertEquals(SplatSession.Loaded.DROPPED, session.timedOut(b))
    assertEquals(listOf("destroy a", "destroy b"), calls)
    // The real event coming after is ignored
    assertEquals(SplatSession.Loaded.IGNORED, session.loaded(b, success = true))
    assertEquals(listOf("destroy a", "destroy b"), calls)
  }

  @Test
  fun `once the scene is down nothing reaches the SDK`() {
    val a = open("a")
    session.loaded(a, success = true)
    calls.clear()
    session.shutDown()
    assertTrue(session.isDown)
    assertNull(session.handle)
    session.drop()
    assertEquals(SplatSession.Loaded.IGNORED, session.loaded(a, success = true))
    assertEquals(SplatSession.Loaded.IGNORED, session.timedOut(a))
    assertFalse(session.prepare())
    var started = false
    session.whenFree { started = true }
    assertFalse(started)
    assertFalse(session.made(Entity("c")))
    assertEquals(emptyList<String>(), calls)
  }

  @Test
  fun `a shutdown while a dropped splat loads forgets it too`() {
    val a = open("a")
    session.drop()
    session.prepare()
    var started = false
    session.whenFree { started = true }
    session.shutDown()
    assertEquals(SplatSession.Loaded.IGNORED, session.loaded(a, success = true))
    assertFalse(started)
    assertEquals(emptyList<String>(), calls)
  }

  @Test
  fun `an entity made for no splat prepared is not kept, and a stale event changes nothing`() {
    assertFalse(session.made(Entity("x")))
    val a = open("a")
    assertEquals(SplatSession.Loaded.IGNORED, session.loaded(Entity("other"), success = true))
    assertEquals(SplatSession.State.LOADING, session.state)
    session.loaded(a, success = true)
    assertEquals(SplatSession.Loaded.IGNORED, session.loaded(a, success = true))
    assertEquals(listOf("show a"), calls)
  }

  @Test
  fun `a media of another kind drops a splat waiting for its turn`() {
    open("a")
    session.drop()
    session.prepare()
    var started = false
    session.whenFree { started = true }
    // A photo now: the splat that waited is not made
    session.drop()
    session.timedOut(session.handle ?: Entity("none"))
    assertFalse(started)
  }

  @Test
  fun `a splat that waited and never starts lets its file go, by a drop, another splat or the shutdown`() {
    // B waits for the end of A, then another media comes: B never starts, its abandon runs once (its file goes)
    val a = open("a")
    session.drop()
    session.prepare()
    val events = mutableListOf<String>()
    session.whenFree(start = { events += "start b" }, abandon = { events += "abandon b" })
    session.drop()
    assertEquals(listOf("abandon b"), events)
    assertEquals(SplatSession.Loaded.DROPPED, session.loaded(a, success = true))
    assertEquals(listOf("abandon b"), events)
    // C waits for D, then E takes its place before D ends: C is abandoned, E starts once D is gone
    val d = open("d")
    session.drop()
    session.prepare()
    session.whenFree(start = { events += "start c" }, abandon = { events += "abandon c" })
    session.whenFree(start = { events += "start e" }, abandon = { events += "abandon e" })
    assertEquals(listOf("abandon b", "abandon c"), events)
    session.loaded(d, success = false)
    assertEquals(listOf("abandon b", "abandon c", "start e"), events)
    // F waits for G, then the scene goes down: F is abandoned, and nothing reaches the SDK
    val g = open("g")
    session.drop()
    session.prepare()
    calls.clear()
    session.whenFree(start = { events += "start f" }, abandon = { events += "abandon f" })
    session.shutDown()
    assertEquals("abandon f", events.last())
    assertEquals(SplatSession.Loaded.IGNORED, session.loaded(g, success = true))
    assertEquals(emptyList<String>(), calls)
    // After the shutdown a start is abandoned at once
    session.whenFree(start = { events += "start h" }, abandon = { events += "abandon h" })
    assertEquals("abandon h", events.last())
    assertFalse("start f" in events || "start h" in events)
  }
}
