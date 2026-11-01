package app.alextran.immich.immersive

import app.alextran.immich.immersive.ImmersiveControls.Action
import app.alextran.immich.immersive.VolumetricSceneSpec.SafeZone
import app.alextran.immich.immersive.scene.SceneNavigation
import app.alextran.immich.immersive.scene.SceneNavigator
import com.meta.spatial.runtime.ButtonBits
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The thumbsticks of a splat, frame by frame at the cadence of the headset (90 and 72 Hz), through the code the viewer
 * runs for them: ControllerEdges (the edges, one direction a push, the repeat of a held turn), ImmersiveControls (the
 * actions of a splat), snapTurnDegrees (30 degrees, the step of the spheres) and the SceneNavigator of the splat (the
 * turn about the head, the glide of the left stick, 0.5 m per second in a zone of 5 m). FreeKC's report of 1 November
 * 2026 with build 39: the right stick turned "sometimes", sometimes by a tiny angle, sometimes not at all, and a turn
 * after a glide put him back in the middle of the scene. In build 39 the right stick did nothing in a splat, and the
 * click that came with most pushes was Reset: the splat placed again from the head, its yaw that of the gaze of the
 * moment, the glide lost. The replay of what he did (stick-timeline-room-2026-11-01.csv, 32 s of the log) gave 42
 * Resets, as many as the log holds.
 */
class SplatStickReplayTest {
  private class Hold(val from: Long, val to: Long, val bit: Int)

  /** The head of the user in the world of the SDK: at 1.6 m, its gaze [yawDegrees] from +z towards +x */
  private class Head(val x: Double = 0.0, val z: Double = 0.0, val yawDegrees: Double = 0.0) {
    val gazeX: Double
      get() = sin(Math.toRadians(yawDegrees))

    val gazeZ: Double
      get() = cos(Math.toRadians(yawDegrees))
  }

  /** What a run of frames gave: the turns, the actions, the frames of the navigator */
  private class Run(val turns: List<Float>, val actions: List<Action>, val frames: List<SceneNavigation>) {
    val yawDegrees: Double
      get() = frames.last().sdkRootYawDegrees - frames.first().sdkRootYawDegrees
  }

  /**
   * [holds] played for [millis] at [hz] frames a second in a splat, the head given by [head] at each time: the order of
   * ImmersiveInputSystem.execute (the edges, onButtonsPressed, onButtonsHeld, onFrame), the actions of a splat as
   * ImmersiveViewerActivity runs them (a turn goes to SplatStage.turn, which turns the navigator about the head at the
   * frame), then the frame of the navigator with the left stick held
   */
  private fun play(holds: List<Hold>, millis: Long, hz: Int, head: (Long) -> Head = { Head() }): Run {
    val edges = ControllerEdges().apply { rightStickTurnsOnly = true }
    val navigator = SceneNavigator(SafeZone(5.0, 5.0, 5.0, 5.0), glideSpeed = 0.5)
    val first = head(0)
    navigator.anchorInSdk(first.x, 1.6, first.z, first.gazeX, first.gazeZ)
    val turns = mutableListOf<Float>()
    val actions = mutableListOf<Action>()
    val frames = mutableListOf<SceneNavigation>()
    frames += navigator.updateInSdk(first.x, 1.6, first.z, first.gazeX, first.gazeZ, 0.0, 0.0, 0.0)
    var frame = 0L
    var last = 0L
    while (true) {
      frame++
      val ms = Math.round(frame * 1000.0 / hz)
      if (ms > millis) break
      val buttons = holds.filter { ms >= it.from && ms < it.to }.fold(0) { bits, hold -> bits or hold.bit }
      val down = edges.pressed(1L, true, "CONTROLLER", buttons, ms)
      var pending = 0f
      if (down != 0) {
        for (action in ImmersiveControls.actionsFor(down, 0, false, scene = true, sceneTurns = true)) {
          actions += action
          val degrees = ImmersiveControls.snapTurnDegrees(action, STEP, false)
          if (degrees != 0f) {
            turns += degrees
            pending += degrees
          }
        }
      }
      val now = head(ms)
      if (pending != 0f) navigator.turnInSdk(now.x, now.z, pending.toDouble())
      val (right, forward) = SceneStick.of(buttons)
      frames +=
        navigator.updateInSdk(now.x, 1.6, now.z, now.gazeX, now.gazeZ, right, forward, (ms - last) / 1000.0)
      last = ms
    }
    return Run(turns, actions, frames)
  }

  /** The splat turned by [degrees] over [run], a whole turn aside */
  private fun assertYaw(degrees: Double, run: Run) =
    assertEquals(0.0, Math.IEEEremainder(run.yawDegrees - degrees, 360.0), 1e-6)

  /** A push of [bit] from [from] for [length] ms */
  private fun push(bit: Int, from: Long, length: Long) = Hold(from, from + length, bit)

  /** The eye never jumps: from one frame to the next it moves no more than the glide does in that frame */
  private fun assertNoJump(run: Run) {
    for (k in 1 until run.frames.size) {
      val a = run.frames[k - 1]
      val b = run.frames[k]
      val moved = hypot(b.eyeX - a.eyeX, b.eyeZ - a.eyeZ)
      assertTrue("frame $k: the eye moved by $moved m", moved <= 0.5 * 0.1 + 1e-9 && moved <= 0.012)
    }
  }

  @Test
  fun `a clean flick of the right stick turns once by the step, the click that comes with it or not`() {
    for (hz in RATES) {
      val clean = play(listOf(push(ButtonBits.ButtonThumbRR, 500, 150)), 1500, hz)
      assertEquals("$hz Hz", listOf(-STEP), clean.turns)
      assertYaw(-30.0, clean)
      assertNoJump(clean)
      // The click 22 ms after the push, as the log shows most of them
      val clicked =
        play(listOf(push(ButtonBits.ButtonThumbRR, 500, 150), push(ButtonBits.ButtonThumbRClick, 522, 50)), 1500, hz)
      assertEquals("$hz Hz", listOf(-STEP), clicked.turns)
      assertEquals(listOf(Action.TURN_RIGHT), clicked.actions)
      // To the left, the head turned 35 degrees: the turn is the step, whatever the head did
      val left =
        play(
          listOf(push(ButtonBits.ButtonThumbRL, 500, 150), push(ButtonBits.ButtonThumbRClick, 522, 50)),
          1500,
          hz,
        ) { ms ->
          Head(yawDegrees = minOf(35.0, ms * 35.0 / 400))
        }
      assertEquals(listOf(STEP), left.turns)
      assertYaw(30.0, left)
      assertNoJump(left)
    }
  }

  @Test
  fun `ten flicks, ten turns of the same angle`() {
    for (hz in RATES) {
      val holds =
        (0 until 10).flatMap { k ->
          val at = 300L + 700 * k
          listOf(push(ButtonBits.ButtonThumbRR, at, 120 + 10L * k), push(ButtonBits.ButtonThumbRClick, at + 15, 50))
        }
      val run = play(holds, 7500, hz)
      assertEquals("$hz Hz", List(10) { -STEP }, run.turns)
      assertYaw(-300.0, run)
      assertNoJump(run)
    }
  }

  @Test
  fun `a stick held turns again after 350 ms, then every 220 ms, as on the spheres`() {
    for (hz in RATES) {
      val run = play(listOf(push(ButtonBits.ButtonThumbRR, 500, 2000)), 3000, hz)
      // The press, then 350, 570, 790, 1010, 1230, 1450, 1670 and 1890 ms after it
      assertEquals("$hz Hz", List(9) { -STEP }, run.turns)
      assertNoJump(run)
    }
  }

  @Test
  fun `a push that crosses down or up before right still turns`() {
    for (hz in RATES) {
      val holds =
        listOf(
          push(ButtonBits.ButtonThumbRD, 500, 200),
          push(ButtonBits.ButtonThumbRR, 530, 150),
          push(ButtonBits.ButtonThumbRClick, 545, 50),
        )
      assertEquals("$hz Hz", listOf(-STEP), play(holds, 1500, hz).turns)
    }
  }

  @Test
  fun `after a glide a turn keeps the user where the glide took him`() {
    for (hz in RATES) {
      val glide = push(ButtonBits.ButtonThumbLU, 200, 2000)
      val run =
        play(
          listOf(
            glide,
            // A click of the left stick as the glide starts, as 17 of the 19 left pushes of the log had one
            push(ButtonBits.ButtonThumbLClick, 215, 50),
            push(ButtonBits.ButtonThumbRR, 3000, 150),
            push(ButtonBits.ButtonThumbRClick, 3022, 50),
          ),
          4000,
          hz,
        )
      // Glided about a metre forward, stopped by 2.9 s
      val glided = run.frames[(2.9 * hz).toInt()]
      val end = run.frames.last()
      assertTrue("glided ${glided.eyeZ}", glided.eyeZ < -0.9)
      // Not back to the middle: still as far into the scene, turned by the step
      assertEquals(glided.eyeZ, end.eyeZ, 1e-9)
      assertEquals(0.0, end.eyeX, 1e-9)
      assertEquals(listOf(-STEP), run.turns)
      assertYaw(-30.0, run)
      assertNoJump(run)
      // Then pushing forward glides towards where the user looks: 30 degrees right of the first forward of the scene
      val turnThenGlide =
        listOf(glide, push(ButtonBits.ButtonThumbRR, 2400, 150), push(ButtonBits.ButtonThumbLU, 3000, 1000))
      val again = play(turnThenGlide, 4200, hz)
      val a = again.frames[(2.9 * hz).toInt()]
      val b = again.frames.last()
      val heading = Math.toDegrees(Math.atan2(b.eyeX - a.eyeX, -(b.eyeZ - a.eyeZ)))
      assertEquals(30.0, heading, 0.5)
    }
  }

  @Test
  fun `the 32 seconds FreeKC played on 1 November turn once a push, never put him back at the start`() {
    val holds = recorded()
    assertEquals(90, holds.size)
    for (hz in RATES) {
      val run = play(holds, 32_000, hz) { ms ->
        // A seated user looking around: the head swaying 20 degrees each way over 7 s
        Head(yawDegrees = 20 * sin(2 * Math.PI * ms / 7000.0))
      }
      // Every action is a turn: no Reset, no previous or next, nothing else of the sticks
      assertTrue(run.actions.all { it == Action.TURN_LEFT || it == Action.TURN_RIGHT })
      assertFalse(run.actions.any { it.name == "RESET" })
      // One turn a push of the right stick to the left or the right, plus the repeats of the pushes held: build 39
      // put the splat back at its start 42 times in the same 32 seconds, by the yaw of the head at each click
      val presses = holds.count { it.bit == ButtonBits.ButtonThumbRL || it.bit == ButtonBits.ButtonThumbRR }
      assertEquals(38, presses)
      assertEquals("$hz Hz", TURNS_OF_THE_REPLAY, run.turns.size)
      assertTrue(run.turns.all { abs(it) == STEP })
      // The yaw of the splat moves by the steps only, whatever the head does
      val sum = run.turns.sum().toDouble()
      assertYaw(sum, run)
      assertNoJump(run)
    }
  }

  private fun recorded(): List<Hold> {
    val text =
      requireNotNull(javaClass.classLoader?.getResource("immersive/stick-timeline-room-2026-11-01.csv")).readText()
    return text.lines()
      .filter { it.isNotBlank() && !it.startsWith("#") }
      .map { line ->
        val (from, to, _, bit) = line.split(',')
        Hold(from.toLong(), to.toLong(), Integer.decode(bit))
      }
  }

  private companion object {
    /** The snap turn of the viewer (ImmersiveViewerActivity.SNAP_TURN_DEGREES) */
    const val STEP = 30f

    /** The refresh rates of the Quest 3 the viewer runs at */
    val RATES = listOf(90, 72)

    /**
     * The turns the replay gives: the 38 pushes to the left or the right and the repeats of those held long enough,
     * one for each of the 56 lines of the log of that window that pressed RL or RR (repeats included)
     */
    const val TURNS_OF_THE_REPLAY = 56
  }
}
