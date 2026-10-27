package app.alextran.immich.relief

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The relief of a flat photo in the immersive view of the Quest (design 3.4, 3.6 and 3.7): the map from the cache or
 * from the model, the right eye of relief-v1, on the thread of the relief; "Stop relief", a hot headset, a new photo
 * or the end of the viewer drop it, a pass of the model goes to its end and its result is thrown away; the model is
 * closed 60 s after the last relief. A fake engine, a fake thread with its own clock, and a real cache folder.
 */
class ReliefJobTest {
  private val folder: File = Files.createTempDirectory("relief-job").toFile()
  private val model = File(folder, "depth_anything_v2_small.tflite").apply { writeBytes(ByteArray(MODEL_SIZE.toInt())) }
  private val cache = ReliefCache(File(folder, ReliefCache.FOLDER))
  private val store = MapStore()
  private val logs = mutableListOf<String>()
  private var nowMs = 0L
  private val worker = FakeWorker { nowMs }
  private val engine = FakeDepthEngine()

  @After
  fun cleanUp() {
    folder.deleteRecursively()
  }

  private companion object {
    const val MODEL_SIZE = 4096L
    const val MODEL_ID = "depth-anything-v2-small@651415f1"
    val KEY = "a".repeat(64)
    val OTHER_KEY = "b".repeat(64)
    const val GIB = 1024L * 1024 * 1024
  }

  /** The preferences of the app, in memory */
  private class MapStore : DepthPathStore {
    val values = mutableMapOf<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String?) {
      if (value == null) values.remove(key) else values[key] = value
    }
  }

  /** The thread of the relief: tasks run when the test says, delayed ones once the clock reaches them */
  private class FakeWorker(private val clock: () -> Long) : ReliefWorker {
    private class Task(val dueMs: Long, val order: Long, val task: Runnable)

    private val tasks = mutableListOf<Task>()
    private var order = 0L
    var quit = false

    override fun post(task: Runnable) {
      if (!quit) tasks += Task(clock(), order++, task)
    }

    override fun postDelayed(task: Runnable, delayMs: Long) {
      if (!quit) tasks += Task(clock() + delayMs, order++, task)
    }

    override fun cancel(task: Runnable) {
      tasks.removeAll { it.task === task }
    }

    override fun quit() {
      quit = true
      tasks.removeAll { it.dueMs > clock() }
    }

    /** Runs every task due now, in order, those they post included */
    fun runDue() {
      while (true) {
        val next = tasks.filter { it.dueMs <= clock() }.minWithOrNull(compareBy({ it.dueMs }, { it.order })) ?: return
        tasks.remove(next)
        next.task.run()
      }
    }

    val pending: Int
      get() = tasks.size
  }

  /** A depth map of the model, nearer to the right */
  private fun ramp(): FloatArray =
    FloatArray(ReliefPreprocess.INPUT_WIDTH * ReliefPreprocess.INPUT_HEIGHT) { i ->
      (i % ReliefPreprocess.INPUT_WIDTH).toFloat()
    }

  /** A fake engine whose estimators count their passes and can act during one (a stop, a hot headset) */
  private inner class FakeDepthEngine : DepthEngine {
    override var available = true
    override val engine = "litert-2.3.0"
    var openFailure: DepthFailure? = null
    var runFailure: DepthFailure? = null
    var duringPass: (DepthPath) -> Unit = {}
    val opened = mutableListOf<DepthPath>()
    var openNow = 0
    var passes = 0

    override fun open(model: File, path: DepthPath): DepthEstimator {
      openFailure?.let { throw DepthEstimatorException(it, path, "no OpenGL ES 3.1 context") }
      opened += path
      openNow += 1
      return FakeDepthEstimator(path)
    }

    inner class FakeDepthEstimator(override val path: DepthPath) : DepthEstimator {
      private var closed = false

      override fun estimate(input: FloatArray): FloatArray {
        check(!closed)
        passes += 1
        nowMs += if (path == DepthPath.GPU) 700 else 2500
        duringPass(path)
        runFailure?.let { throw DepthEstimatorException(it, path, "the pass failed") }
        return ramp()
      }

      override fun close() {
        if (!closed) {
          closed = true
          openNow -= 1
        }
      }
    }
  }

  /** A photo of [width] x [height], a gradient, that counts its rows and its release */
  private class FakePhoto(override val width: Int, override val height: Int) : ReliefPhoto {
    val pixels = IntArray(width * height) { i -> (0xFF shl 24) or ((i % width * 255 / width) shl 16) or 0x4080 }
    var released = 0

    override fun read(y: Int, out: IntArray) {
      check(released == 0) { "a photo read after its release" }
      pixels.copyInto(out, 0, y * width, (y + 1) * width)
    }

    override fun release() {
      released += 1
    }
  }

  /** The right eye, written row by row; [onRow] acts after a row is written */
  private class FakeEye(val width: Int, val height: Int, val onRow: (Int) -> Unit = {}) : ReliefEye {
    val pixels = IntArray(width * height)
    var rows = 0
    var released = 0

    override fun write(y: Int, row: IntArray) {
      row.copyInto(pixels, y * width, 0, width)
      rows += 1
      onRow(y)
    }

    override fun release() {
      released += 1
    }
  }

  /** What the viewer is told, in order */
  private class Recorder : ReliefListener<FakePhoto, FakeEye> {
    val stages = mutableListOf<ReliefStage>()
    val done = mutableListOf<ReliefResult<FakePhoto, FakeEye>>()
    val flat = mutableListOf<Pair<ReliefStop, String>>()

    override fun onStage(stage: ReliefStage) {
      stages += stage
    }

    override fun onDone(result: ReliefResult<FakePhoto, FakeEye>) {
      done += result
    }

    override fun onFlat(reason: ReliefStop, detail: String) {
      flat += reason to detail
    }
  }

  private var thermal = 0
  private val eyes = mutableListOf<FakeEye>()
  private var eyeRow: (Int) -> Unit = {}

  private fun job(
    preferred: DepthPath = DepthPath.CPU,
    totalMemoryBytes: Long = 7 * GIB,
    available: Boolean = true,
    cache: ReliefCache = this.cache,
  ): ReliefJob {
    engine.available = available
    return ReliefJob(
      engine = engine,
      memory = DepthPathMemory(store, "eureka/release-keys", engine.engine),
      cache = cache,
      worker = worker,
      main = { it.run() },
      thermalStatus = { thermal },
      totalMemoryBytes = totalMemoryBytes,
      log = { logs += it },
      nanoTime = { nowMs * 1_000_000 },
      preferred = preferred,
    )
  }

  private fun request(key: String = KEY, size: Long = MODEL_SIZE) =
    ReliefRequest(model, size, MODEL_ID, key, ReliefV1.PARALLAX, ReliefV1.CONVERGENCE)

  private fun start(
    job: ReliefJob,
    photo: FakePhoto,
    recorder: Recorder,
    request: ReliefRequest = request(),
  ): ReliefRun = job.start(request, photo, { w, h -> FakeEye(w, h) { eyeRow(it) }.also { eyes += it } }, recorder)

  /** The right eye relief-v1 makes of [photo] from [map] */
  private fun expectedEye(photo: FakePhoto, map: ReliefMap): IntArray {
    val out = IntArray(photo.width * photo.height)
    ReliefSynthesizer.rightEye(photo.pixels, photo.width, photo.height, map.toNormalized(), map.width, map.height, out)
    return out
  }

  @Test
  fun `a relief goes through its stages and hands the photo and its right eye to the viewer`() {
    val job = job(preferred = DepthPath.GPU)
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()

    val run = start(job, photo, recorder)
    assertTrue(run.running)
    assertTrue(recorder.stages.isEmpty())
    worker.runDue()

    assertEquals(listOf(ReliefStage.PREPARING, ReliefStage.ESTIMATING, ReliefStage.BUILDING), recorder.stages)
    assertTrue(recorder.flat.isEmpty())
    val result = recorder.done.single()
    assertFalse(run.running)
    // The first relief on this headset checks the GPU against the CPU: the same map, the GPU is kept
    assertEquals(listOf(DepthPath.CPU, DepthPath.GPU), engine.opened)
    assertEquals(DepthPath.GPU, result.path)
    assertFalse(result.fromCache)
    // The viewer owns both now: nothing released
    assertEquals(0, photo.released)
    assertEquals(0, result.eye.released)
    assertEquals(48, result.eye.rows)
    // The map went to the cache, and the eye is the one relief-v1 makes from it
    val map = cache.read(KEY)
    assertNotNull(map)
    assertEquals(686 to 518, map!!.width to map.height)
    assertArrayEquals(expectedEye(photo, map), result.eye.pixels)
    // The map comes with the eyes, as the cache keeps it: the 2.5D view moves its mesh with it
    assertEquals(map.width to map.height, result.map.width to result.map.height)
    assertArrayEquals(map.levels, result.map.levels)
  }

  @Test
  fun `the map comes with the eyes even when the cache cannot keep it`() {
    val full = File(folder, "full")
    full.writeText("a file where the folder of the cache should be")
    val job = job(cache = ReliefCache(File(full, "ai-relief")))
    val recorder = Recorder()

    start(job, FakePhoto(64, 48), recorder)
    worker.runDue()

    val result = recorder.done.single()
    assertEquals(686 to 518, result.map.width to result.map.height)
    assertArrayEquals(expectedEye(FakePhoto(64, 48), result.map), result.eye.pixels)
  }

  @Test
  fun `a map in the cache skips the model`() {
    val job = job()
    val photo = FakePhoto(64, 48)
    val map = ReliefMap(16, 12, ShortArray(16 * 12) { i -> ((i % 16) * 4000).toShort() })
    assertNotNull(cache.write(KEY, map))
    val recorder = Recorder()

    start(job, photo, recorder)
    worker.runDue()

    assertTrue(engine.opened.isEmpty())
    assertEquals(0, engine.passes)
    assertEquals(listOf(ReliefStage.PREPARING, ReliefStage.BUILDING), recorder.stages)
    val result = recorder.done.single()
    assertTrue(result.fromCache)
    assertNull(result.path)
    assertArrayEquals(expectedEye(photo, map), result.eye.pixels)
    assertArrayEquals(map.levels, result.map.levels)
    // No model open, nothing to close later
    assertEquals(0, worker.pending)
  }

  @Test
  fun `the second look at a photo comes from the cache with the same right eye`() {
    val job = job()
    val first = Recorder()
    start(job, FakePhoto(64, 48), first)
    worker.runDue()
    val second = Recorder()
    start(job, FakePhoto(64, 48), second)
    worker.runDue()

    assertEquals(1, engine.passes)
    assertTrue(second.done.single().fromCache)
    assertArrayEquals(first.done.single().eye.pixels, second.done.single().eye.pixels)
  }

  @Test
  fun `a failure of the engine leaves the photo flat with its reason`() {
    val job = job()
    engine.openFailure = DepthFailure.OPEN_FAILED
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()

    val run = start(job, photo, recorder)
    worker.runDue()

    assertTrue(recorder.done.isEmpty())
    val (reason, detail) = recorder.flat.single()
    assertEquals(ReliefStop.FAILED, reason)
    assertTrue(detail, detail.contains("no OpenGL ES 3.1 context"))
    assertFalse(run.running)
    assertEquals(1, photo.released)
    assertTrue(eyes.isEmpty())
    assertNull(cache.read(KEY))
  }

  @Test
  fun `a pass that fails leaves the photo flat with its reason`() {
    val job = job()
    engine.runFailure = DepthFailure.RUN_FAILED
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()

    start(job, photo, recorder)
    worker.runDue()

    assertEquals(ReliefStop.FAILED, recorder.flat.single().first)
    assertEquals(1, photo.released)
    assertTrue(recorder.done.isEmpty())
  }

  @Test
  fun `a failure the engine names gets its own reason`() {
    for ((failure, reason) in
      listOf(
        DepthFailure.WRONG_MODEL to ReliefStop.MODEL_DAMAGED,
        DepthFailure.MODEL_MISSING to ReliefStop.MODEL_MISSING,
        DepthFailure.NOT_IN_THIS_VERSION to ReliefStop.NOT_IN_THIS_VERSION,
      )) {
      engine.openFailure = failure
      val recorder = Recorder()
      val photo = FakePhoto(32, 24)
      start(job(), photo, recorder)
      worker.runDue()
      assertEquals(failure.name, reason, recorder.flat.single().first)
      assertEquals(1, photo.released)
    }
  }

  @Test
  fun `a missing model or a model of another size is said before the engine opens it`() {
    val job = job()
    val damaged = Recorder()
    start(job, FakePhoto(32, 24), damaged, request(size = MODEL_SIZE + 1))
    worker.runDue()
    model.delete()
    val missing = Recorder()
    start(job, FakePhoto(32, 24), missing)
    worker.runDue()

    assertEquals(ReliefStop.MODEL_DAMAGED, damaged.flat.single().first)
    assertEquals(ReliefStop.MODEL_MISSING, missing.flat.single().first)
    assertTrue(engine.opened.isEmpty())
  }

  @Test
  fun `the headset checks the gate again without touching the engine`() {
    val phone = Recorder()
    val phonePhoto = FakePhoto(32, 24)
    start(job(available = false), phonePhoto, phone)
    val small = Recorder()
    start(job(totalMemoryBytes = 4 * GIB + GIB / 2), FakePhoto(32, 24), small)
    thermal = ReliefJob.THERMAL_STATUS_SEVERE
    val hot = Recorder()
    start(job(), FakePhoto(32, 24), hot)
    worker.runDue()

    assertEquals(ReliefStop.NOT_IN_THIS_VERSION, phone.flat.single().first)
    assertEquals(ReliefStop.NOT_ENOUGH_MEMORY, small.flat.single().first)
    assertEquals(ReliefStop.TOO_WARM, hot.flat.single().first)
    assertEquals(1, phonePhoto.released)
    assertTrue(engine.opened.isEmpty())
    assertEquals(0, worker.pending)
  }

  @Test
  fun `5 GiB seen by Android is enough`() {
    val recorder = Recorder()
    start(job(totalMemoryBytes = 5 * GIB), FakePhoto(32, 24), recorder)
    worker.runDue()

    assertEquals(1, recorder.done.size)
  }

  @Test
  fun `Stop relief keeps the photo flat and the model is never asked`() {
    val job = job()
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()

    val run = start(job, photo, recorder)
    job.stop(run)

    // Said at once: the button and the status line come back without waiting for the thread
    assertEquals(listOf(ReliefStop.STOPPED to ""), recorder.flat)
    assertFalse(run.running)
    worker.runDue()
    assertTrue(engine.opened.isEmpty())
    assertTrue(recorder.stages.isEmpty())
    assertTrue(recorder.done.isEmpty())
    assertEquals(1, recorder.flat.size)
    assertEquals(1, photo.released)
  }

  @Test
  fun `a pass stopped while it runs goes to its end and its map is thrown away`() {
    val job = job()
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()
    lateinit var run: ReliefRun
    engine.duringPass = { job.stop(run) }

    run = start(job, photo, recorder)
    worker.runDue()

    assertEquals(1, engine.passes)
    assertEquals(listOf(ReliefStop.STOPPED to ""), recorder.flat)
    assertTrue(recorder.done.isEmpty())
    assertEquals(listOf(ReliefStage.PREPARING, ReliefStage.ESTIMATING), recorder.stages)
    assertTrue(eyes.isEmpty())
    assertNull(cache.read(KEY))
    assertEquals(1, photo.released)
  }

  @Test
  fun `a pass that fails after Stop relief says nothing more than the stop`() {
    val job = job()
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()
    lateinit var run: ReliefRun
    engine.duringPass = { job.stop(run) }
    engine.runFailure = DepthFailure.RUN_FAILED

    run = start(job, photo, recorder)
    worker.runDue()

    // The user asked for the stop: "The relief failed" would not be the answer
    assertEquals(listOf(ReliefStop.STOPPED to ""), recorder.flat)
    assertTrue(recorder.done.isEmpty())
    assertEquals(1, photo.released)
  }

  @Test
  fun `a right eye stopped halfway is dropped`() {
    val job = job()
    val photo = FakePhoto(40, 200)
    val recorder = Recorder()
    lateinit var run: ReliefRun
    eyeRow = { y -> if (y == 10) job.stop(run) }

    run = start(job, photo, recorder)
    worker.runDue()

    assertEquals(listOf(ReliefStop.STOPPED to ""), recorder.flat)
    assertTrue(recorder.done.isEmpty())
    val eye = eyes.single()
    // The cancellation is looked for every 64 rows
    assertEquals(ReliefV1.CANCEL_CHECK_ROWS, eye.rows)
    assertEquals(1, eye.released)
    assertEquals(1, photo.released)
  }

  @Test
  fun `a hot headset stops the relief and says so`() {
    val job = job()
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()
    engine.duringPass = { job.onThermalStatus(ReliefJob.THERMAL_STATUS_SEVERE) }

    start(job, photo, recorder)
    worker.runDue()

    assertEquals(listOf(ReliefStop.TOO_WARM to ""), recorder.flat)
    assertTrue(recorder.done.isEmpty())
    assertEquals(1, photo.released)
  }

  @Test
  fun `a warm but not severe headset goes on`() {
    val job = job()
    val recorder = Recorder()
    thermal = ReliefJob.THERMAL_STATUS_SEVERE - 1
    engine.duringPass = { job.onThermalStatus(ReliefJob.THERMAL_STATUS_SEVERE - 1) }

    start(job, FakePhoto(64, 48), recorder)
    worker.runDue()

    assertEquals(1, recorder.done.size)
    assertTrue(recorder.flat.isEmpty())
  }

  @Test
  fun `a new photo drops the relief of the one before without a word`() {
    val job = job()
    val first = FakePhoto(64, 48)
    val firstRecorder = Recorder()
    val firstRun = start(job, first, firstRecorder)
    val second = FakePhoto(48, 64)
    val secondRecorder = Recorder()
    start(job, second, secondRecorder, request(OTHER_KEY))
    worker.runDue()

    assertFalse(firstRun.running)
    assertTrue(firstRecorder.stages.isEmpty() && firstRecorder.done.isEmpty() && firstRecorder.flat.isEmpty())
    assertEquals(1, first.released)
    assertEquals(1, secondRecorder.done.size)
    assertEquals(1, engine.passes)
  }

  @Test
  fun `a photo that goes away drops its relief without a word`() {
    val job = job()
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()
    val run = start(job, photo, recorder)

    job.cancel()
    worker.runDue()

    assertFalse(run.running)
    assertTrue(recorder.stages.isEmpty() && recorder.done.isEmpty() && recorder.flat.isEmpty())
    assertEquals(1, photo.released)
    assertTrue(engine.opened.isEmpty())
  }

  @Test
  fun `the model is closed 60 s after the last relief`() {
    val job = job()
    start(job, FakePhoto(64, 48), Recorder())
    worker.runDue()
    assertEquals(1, engine.openNow)

    nowMs += ReliefJob.IDLE_CLOSE_MS - 1
    worker.runDue()
    assertEquals(1, engine.openNow)
    nowMs += 1
    worker.runDue()
    assertEquals(0, engine.openNow)

    // The next relief opens it again
    start(job, FakePhoto(64, 48), Recorder(), request(OTHER_KEY))
    worker.runDue()
    assertEquals(1, engine.openNow)
    assertEquals(2, engine.opened.size)
  }

  @Test
  fun `a relief within the 60 s keeps the model open and starts the wait again`() {
    val job = job()
    start(job, FakePhoto(64, 48), Recorder())
    worker.runDue()
    nowMs += 30_000
    worker.runDue()
    start(job, FakePhoto(64, 48), Recorder(), request(OTHER_KEY))
    worker.runDue()
    assertEquals(1, engine.opened.size)

    nowMs += ReliefJob.IDLE_CLOSE_MS - 1
    worker.runDue()
    assertEquals(1, engine.openNow)
    nowMs += 1
    worker.runDue()
    assertEquals(0, engine.openNow)
  }

  @Test
  fun `the end of the viewer drops the relief, closes the model and the thread`() {
    val job = job()
    start(job, FakePhoto(64, 48), Recorder())
    worker.runDue()
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()
    val run = start(job, photo, recorder, request(OTHER_KEY))

    job.close()
    worker.runDue()

    assertFalse(run.running)
    assertTrue(recorder.stages.isEmpty() && recorder.done.isEmpty() && recorder.flat.isEmpty())
    assertEquals(1, photo.released)
    assertEquals(0, engine.openNow)
    assertTrue(worker.quit)
    assertEquals(0, worker.pending)
  }

  @Test
  fun `a stop after the relief is done changes nothing`() {
    val job = job()
    val recorder = Recorder()
    val run = start(job, FakePhoto(64, 48), recorder)
    worker.runDue()

    job.stop(run)
    job.onThermalStatus(ReliefJob.THERMAL_STATUS_SEVERE)

    assertEquals(1, recorder.done.size)
    assertTrue(recorder.flat.isEmpty())
  }

  @Test
  fun `a relief that ends after the viewer dropped it gives back its photo and its eye`() {
    // The thread ends the relief, then the main thread finds the run dropped meanwhile
    val posted = mutableListOf<Runnable>()
    engine.available = true
    val job =
      ReliefJob(
        engine = engine,
        memory = DepthPathMemory(store, "eureka/release-keys", engine.engine),
        cache = cache,
        worker = worker,
        main = { posted += it },
        thermalStatus = { 0 },
        totalMemoryBytes = 7 * GIB,
        preferred = DepthPath.CPU,
      )
    val photo = FakePhoto(64, 48)
    val recorder = Recorder()
    val run = start(job, photo, recorder)
    worker.runDue()

    job.stop(run)
    posted.forEach { it.run() }

    assertEquals(listOf(ReliefStop.STOPPED to ""), recorder.flat)
    assertTrue(recorder.stages.isEmpty())
    assertTrue(recorder.done.isEmpty())
    assertEquals(1, photo.released)
    assertEquals(1, eyes.single().released)
  }
}
