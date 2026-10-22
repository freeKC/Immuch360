package app.alextran.immich.djilink

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transport on a pair of pipes. No accessory can be emulated anywhere, so what is tested here is what the
 * transport itself promises: it reads what arrives, it hands the duration of the probe call back, and it gives up
 * after the documented number of failures in a row.
 */
class AoaTransportTest {
  private class Pipes(override val input: InputStream, override val output: OutputStream) : AccessoryStreams {
    override fun close() {
      runCatching { input.close() }
      runCatching { output.close() }
    }
  }

  /** A stream that stays open and says nothing, which is what a remote that never speaks looks like */
  private class SilentInput : InputStream() {
    private val writer = PipedOutputStream()
    private val reader = PipedInputStream(writer, 16)

    override fun read(): Int = reader.read()

    override fun read(bytes: ByteArray, offset: Int, length: Int): Int = reader.read(bytes, offset, length)

    override fun close() {
      runCatching { writer.close() }
      runCatching { reader.close() }
    }
  }

  private class FailingOutput(private val failures: Int) : OutputStream() {
    val attempts = AtomicInteger(0)

    override fun write(byte: Int) {
      write(byteArrayOf(byte.toByte()), 0, 1)
    }

    override fun write(bytes: ByteArray, offset: Int, length: Int) {
      if (attempts.incrementAndGet() <= failures) {
        throw IOException("the host is not reading")
      }
    }
  }

  @Test
  fun bytesThatArriveReachTheCallback() {
    val toApplication = PipedOutputStream()
    val applicationInput = PipedInputStream(toApplication, 1024)
    val seen = StringBuilder()
    val arrived = CountDownLatch(1)
    val transport = AoaTransport(
      streams = Pipes(applicationInput, ByteArrayOutputStream()),
      onBytes = { data, length ->
        seen.append(String(data, 0, length))
        arrived.countDown()
      },
      log = {},
    )
    transport.start()
    toApplication.write("hello".toByteArray())
    toApplication.flush()
    assertTrue(arrived.await(2, TimeUnit.SECONDS))
    assertEquals("hello", seen.toString())
    assertEquals(5L, transport.bytesRead)
    assertEquals(1L, transport.reads)
    transport.stop(LinkReason.PAGE_CLOSED)
    assertFalse(transport.isRunning)
  }

  @Test
  fun theProbeWritesOneByteAndReportsHowLongTheCallTook() {
    val written = ByteArrayOutputStream()
    val transport = AoaTransport(streams = Pipes(SilentInput(), written), onBytes = { _, _ -> }, log = {})
    transport.start()
    val result = transport.probe()
    assertTrue(result.ok)
    assertTrue(result.callMs >= 0)
    assertEquals(1, written.size())
    assertEquals(1L, transport.writes)
    assertEquals(1L, transport.bytesWritten)
    transport.stop(LinkReason.PAGE_CLOSED)
  }

  @Test
  fun aFailedProbeIsAnAnswerAndTenInARowEndTheTransport() {
    val output = FailingOutput(failures = 100)
    val ended = CountDownLatch(1)
    val transport = AoaTransport(
      streams = Pipes(SilentInput(), output),
      onBytes = { _, _ -> },
      onEnded = { ended.countDown() },
      log = {},
    )
    transport.start()
    var failures = 0
    repeat(AoaTransport.MAX_CONSECUTIVE_ERRORS) {
      if (!transport.probe().ok) {
        failures += 1
      }
    }
    assertEquals(AoaTransport.MAX_CONSECUTIVE_ERRORS, failures)
    assertTrue(ended.await(2, TimeUnit.SECONDS))
    assertFalse(transport.isRunning)
    assertEquals(AoaTransport.MAX_CONSECUTIVE_ERRORS.toLong(), transport.writeErrors)
  }

  /** A remote that never collects our transfers: the write call does not return */
  private class BlockingOutput : OutputStream() {
    private val release = CountDownLatch(1)

    override fun write(byte: Int) {
      release.await(5, TimeUnit.SECONDS)
    }

    override fun write(bytes: ByteArray, offset: Int, length: Int) {
      release.await(5, TimeUnit.SECONDS)
    }

    override fun close() {
      release.countDown()
    }
  }

  @Test
  fun aProbeWhoseWriteDoesNotReturnIsReportedAsBlocked() {
    val output = BlockingOutput()
    val transport = AoaTransport(streams = Pipes(SilentInput(), output), onBytes = { _, _ -> }, log = {})
    transport.start()
    val result = transport.probe(timeoutMs = 100)
    assertFalse(result.ok)
    assertTrue(result.blocked)
    transport.stop(LinkReason.PAGE_CLOSED)
  }

  @Test
  fun aProbeInterruptedWhileItWaitsReturnsAnAnswer() {
    val transport = AoaTransport(streams = Pipes(SilentInput(), BlockingOutput()), onBytes = { _, _ -> }, log = {})
    transport.start()
    var result: ProbeResult? = null
    var thrown: Throwable? = null
    val prober = Thread {
      try {
        result = transport.probe(timeoutMs = 10_000)
      } catch (error: Throwable) {
        thrown = error
      }
    }
    prober.start()
    Thread.sleep(200)
    // What closing the page does to the probe thread
    prober.interrupt()
    prober.join(2_000)
    assertFalse(prober.isAlive)
    assertEquals(null, thrown)
    assertFalse(result!!.ok)
    assertFalse(result!!.blocked)
    assertEquals("interrupted", result!!.error)
    transport.stop(LinkReason.PAGE_CLOSED)
  }

  @Test
  fun sendRefusesEveryByteWhileTheBuildSwitchIsOff() {
    val output = FailingOutput(failures = 0)
    val transport = AoaTransport(streams = Pipes(SilentInput(), output), onBytes = { _, _ -> }, log = {})
    transport.start()
    assertFalse(DjiLinkBuild.SEND_ENABLED)
    assertFalse(transport.send(byteArrayOf(0x55, 0x0D, 0x04)))
    assertFalse(transport.send(ByteArray(13)))
    Thread.sleep(300)
    assertEquals(0, output.attempts.get())
    assertEquals(0L, transport.writes)
    assertEquals(2L, transport.sendRefusals)
    transport.stop(LinkReason.PAGE_CLOSED)
  }

  @Test
  fun theTransportWritesNothingOnItsOwn() {
    val output = FailingOutput(failures = 0)
    val transport = AoaTransport(streams = Pipes(SilentInput(), output), onBytes = { _, _ -> }, log = {})
    transport.start()
    Thread.sleep(300)
    assertEquals(0, output.attempts.get())
    assertEquals(0L, transport.writes)
    transport.stop(LinkReason.PAGE_CLOSED)
  }
}
