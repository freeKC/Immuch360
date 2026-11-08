package app.alextran.immich.core

import com.example.ok_http.RedirectInterceptor
import com.example.ok_http.RedirectReceivedCallback
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.Headers
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSink
import okio.BufferedSource
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * The redirect interceptor of package:ok_http (mobile/packages/ok_http), which every request of the Dart API client
 * goes through on Android. A relative Location ended the app (IllegalArgumentException on OkHttp's dispatcher thread,
 * Meta Horizon build 3030023, upstream Immich issues 28535 and 30132).
 *
 * No network: a fake server, an application interceptor added after the redirect interceptor, answers from a table and
 * records the requests it gets.
 */
class OkHttpRedirectTest {
  private var previousHandler: Thread.UncaughtExceptionHandler? = null
  private val uncaught = CopyOnWriteArrayList<Throwable>()

  @Before
  fun recordUncaughtExceptions() {
    previousHandler = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { _, error -> uncaught.add(error) }
  }

  @After
  fun restore() {
    Thread.setDefaultUncaughtExceptionHandler(previousHandler)
    RedirectInterceptor.onUnusualRedirect = null
  }

  @Test
  fun `a relative Location is followed to the URL it resolves to`() {
    val server = FakeServer(
      "https://immich.example/.well-known/immich" to Answer(302, "/api/i"),
      "https://immich.example/api/i" to Answer(200, body = "ok"),
    )
    val locations = CopyOnWriteArrayList<String>()

    val response = client(server, callback = recordTo(locations))
      .newCall(get("https://immich.example/.well-known/immich"))
      .execute()

    assertEquals(200, response.code)
    assertEquals("ok", response.body!!.string())
    assertEquals(
      listOf("https://immich.example/.well-known/immich", "https://immich.example/api/i"),
      server.urls(),
    )
    assertEquals(listOf("https://immich.example/api/i"), locations)
  }

  @Test
  fun `a relative Location on the dispatcher thread gives the answer and leaves no uncaught exception`() {
    // The crash of the field: package:ok_http sends every request with enqueue
    val server = FakeServer(
      "https://immich.example/.well-known/immich" to Answer(302, "/api/i"),
      "https://immich.example/api/i" to Answer(200, body = "ok"),
    )

    val outcome = enqueue(server, get("https://immich.example/.well-known/immich"))

    assertEquals(200, outcome.response?.code)
    assertNull(outcome.failure)
    assertEquals(emptyList<Throwable>(), uncaught)
  }

  @Test
  fun `relative, scheme relative and query only Locations resolve against the request`() {
    val server = FakeServer(
      "https://immich.example/a/b" to Answer(302, "next"),
      "https://immich.example/a/next" to Answer(301, "//other.example/x"),
      "https://other.example/x" to Answer(307, "?page=2"),
      "https://other.example/x?page=2" to Answer(200),
    )

    val response = client(server).newCall(get("https://immich.example/a/b")).execute()

    assertEquals(200, response.code)
    assertEquals(
      listOf(
        "https://immich.example/a/b",
        "https://immich.example/a/next",
        "https://other.example/x",
        "https://other.example/x?page=2",
      ),
      server.urls(),
    )
  }

  @Test
  fun `Authorization follows on the same origin only, not to another host, port or scheme`() {
    for (target in listOf("https://other.example/c", "https://immich.example:8443/c", "http://immich.example/c")) {
      val server = FakeServer(
        "https://immich.example/a" to Answer(302, "https://immich.example/b"),
        "https://immich.example/b" to Answer(302, target),
        target to Answer(200),
      )
      val request = Request.Builder().url("https://immich.example/a").header("Authorization", "Bearer secret").build()

      val response = client(server).newCall(request).execute()

      assertEquals(target, 200, response.code)
      assertEquals(
        target,
        listOf("Bearer secret", "Bearer secret", null),
        server.seen.map { it.headers["Authorization"] },
      )
    }
  }

  @Test
  fun `a Location that is not an http or https URL gives the redirect back`() {
    for (location in listOf("app.immich:///oauth-callback", "http://")) {
      val server = FakeServer("https://immich.example/auth" to Answer(302, location))

      val response = client(server).newCall(get("https://immich.example/auth")).execute()

      assertEquals(location, 302, response.code)
      assertEquals(location, location, response.header("Location"))
      assertEquals(location, 1, server.seen.size)
    }
  }

  @Test
  fun `a redirect without Location gives the redirect back`() {
    val server = FakeServer("https://immich.example/choices" to Answer(300))

    val response = client(server).newCall(get("https://immich.example/choices")).execute()

    assertEquals(300, response.code)
    assertEquals(1, server.seen.size)
  }

  @Test
  fun `303 turns a POST into a GET without body, 301, 302, 307 and 308 send the same POST again`() {
    val bytes = """{"email":"a@b.c"}""".toByteArray()
    for ((status, method) in listOf(303 to "GET", 302 to "POST", 307 to "POST", 308 to "POST", 301 to "POST")) {
      val server = FakeServer(
        "https://immich.example/api/auth/login" to Answer(status, "https://immich.example/api/auth/login2"),
        "https://immich.example/api/auth/login2" to Answer(201),
      )
      val request = Request.Builder()
        .url("https://immich.example/api/auth/login")
        .header("Content-Type", "application/json")
        .post(bytes.toRequestBody(null))
        .build()

      val response = client(server).newCall(request).execute()

      assertEquals("$status", 201, response.code)
      val second = server.seen[1]
      assertEquals("$status", method, second.method)
      if (method == "GET") {
        assertNull("$status", second.body)
        assertNull("$status", second.headers["Content-Type"])
      } else {
        assertArrayEquals("$status", bytes, second.body)
        assertEquals("$status", "application/json", second.headers["Content-Type"])
      }
    }
  }

  @Test
  fun `a streamed body is never sent twice, the redirect comes back`() {
    val server = FakeServer(
      "https://immich.example/api/assets" to Answer(307, "https://immich.example/api/assets2"),
      "https://immich.example/api/assets2" to Answer(201),
    )
    val body = OneShotBody(ByteArray(1000) { it.toByte() })
    val request = Request.Builder().url("https://immich.example/api/assets").post(body).build()

    val response = client(server).newCall(request).execute()

    assertEquals(307, response.code)
    assertEquals(1, server.seen.size)
    assertEquals(1, body.writes.get())
  }

  @Test
  fun `a 303 after a streamed body is followed with a GET, the body is not sent again`() {
    val server = FakeServer(
      "https://immich.example/api/assets" to Answer(303, "https://immich.example/api/assets/1"),
      "https://immich.example/api/assets/1" to Answer(200),
    )
    val body = OneShotBody(ByteArray(10))
    val request = Request.Builder().url("https://immich.example/api/assets").post(body).build()

    val response = client(server).newCall(request).execute()

    assertEquals(200, response.code)
    assertEquals(listOf("POST", "GET"), server.seen.map { it.method })
    assertEquals(1, body.writes.get())
  }

  @Test
  fun `five redirects of five allowed succeed`() {
    val server = FakeServer(*chain(5))

    val response = client(server, maxRedirects = 5).newCall(get("https://immich.example/r/0")).execute()

    assertEquals(200, response.code)
    assertEquals(6, server.seen.size)
  }

  @Test
  fun `six redirects of five allowed fail and close every answer`() {
    val server = FakeServer(*chain(6))

    val error = assertThrows { client(server, maxRedirects = 5).newCall(get("https://immich.example/r/0")).execute() }

    assertEquals("Redirect limit exceeded", error.message)
    assertEquals(6, server.seen.size)
    assertTrue(server.bodies.all { it.closed })
  }

  @Test
  fun `a redirect loop fails`() {
    val server = FakeServer("https://immich.example/loop" to Answer(302, "https://immich.example/loop"))

    val error = assertThrows { client(server, maxRedirects = 5).newCall(get("https://immich.example/loop")).execute() }

    assertEquals("Redirect limit exceeded", error.message)
  }

  @Test
  fun `no redirect allowed fails at the first one`() {
    val server = FakeServer(*chain(1))

    val error = assertThrows { client(server, maxRedirects = 0).newCall(get("https://immich.example/r/0")).execute() }

    assertEquals("Redirect limit exceeded", error.message)
    assertEquals(1, server.seen.size)
  }

  @Test
  fun `more than twenty redirects are never followed, whatever the caller asks`() {
    val server = FakeServer("https://immich.example/loop" to Answer(302, "https://immich.example/loop"))
    val client = client(server, maxRedirects = 1000)

    val error = assertThrows { client.newCall(get("https://immich.example/loop")).execute() }

    assertEquals("Redirect limit exceeded", error.message)
    assertEquals(RedirectInterceptor.MAX_REDIRECTS + 1, server.seen.size)
  }

  @Test
  fun `redirects not followed give the first answer`() {
    val server = FakeServer(*chain(1))

    val response = client(server, follow = false).newCall(get("https://immich.example/r/0")).execute()

    assertEquals(302, response.code)
    assertEquals(1, server.seen.size)
  }

  @Test
  fun `a RuntimeException below the interceptor becomes an IOException`() {
    val failure = IllegalStateException("Unable to load PublicSuffixDatabase.list resource")
    val server = FakeServer(failure = failure)

    val error = assertThrows { client(server).newCall(get("https://immich.example/a")).execute() }

    assertSame(failure, error.cause)
  }

  @Test
  fun `a RuntimeException on the dispatcher thread is a failed call, not an uncaught exception`() {
    val failure = IllegalStateException("boom")
    val server = FakeServer(failure = failure)

    val outcome = enqueue(server, get("https://immich.example/a"))

    assertNull(outcome.response)
    assertSame(failure, outcome.failure?.cause)
    assertEquals(emptyList<Throwable>(), uncaught)
  }

  @Test
  fun `unusual redirects are reported once, without query string or user info`() {
    val reports = CopyOnWriteArrayList<String>()
    RedirectInterceptor.onUnusualRedirect = { reports.add(it) }
    val server = FakeServer(
      "https://user:pw@relative.example/.well-known/immich?token=abc" to Answer(302, "/api/i?key=secret"),
      "https://user:pw@relative.example/api/i?key=secret" to Answer(200),
      "https://absolute.example/a" to Answer(302, "https://absolute.example/b?key=secret"),
      "https://absolute.example/b?key=secret" to Answer(200),
      "https://unusable.example/auth" to Answer(302, "app.immich://user:pw@callback/oauth?code=secret#frag"),
      "https://oneshot.example/upload" to Answer(307, "/upload2"),
    )
    val client = client(server)

    client.newCall(get("https://user:pw@relative.example/.well-known/immich?token=abc")).execute()
    client.newCall(get("https://user:pw@relative.example/.well-known/immich?token=abc")).execute()
    client.newCall(get("https://absolute.example/a")).execute()
    client.newCall(get("https://unusable.example/auth")).execute()
    client.newCall(
      Request.Builder().url("https://oneshot.example/upload").post(OneShotBody(ByteArray(10))).build(),
    ).execute()

    assertEquals(
      listOf(
        "Redirect 302 of GET https://relative.example/.well-known/immich to a relative Location, resolved to " +
          "https://relative.example/api/i",
        "Redirect 302 of GET https://unusable.example/auth not followed: its Location app.immich://callback/oauth " +
          "is not an http or https URL",
        "Redirect 307 of POST https://oneshot.example/upload to https://oneshot.example/upload2 not followed: the " +
          "body was streamed and cannot be sent again",
      ),
      reports,
    )
    for (report in reports) {
      assertFalse(report, report.contains("secret") || report.contains("token") || report.contains("pw"))
      assertFalse(report, report.contains('?') || report.contains('#'))
    }
  }

  @Test
  fun `a failing report does not fail the request`() {
    RedirectInterceptor.onUnusualRedirect = { throw IllegalStateException("no report") }
    val server = FakeServer(
      "https://failing-report.example/a" to Answer(302, "b"),
      "https://failing-report.example/b" to Answer(200),
    )

    val response = client(server).newCall(get("https://failing-report.example/a")).execute()

    assertEquals(200, response.code)
  }

  // The client as package:ok_http builds it for each request: OkHttp's own redirects off, the redirect interceptor on
  private fun client(
    server: FakeServer,
    maxRedirects: Int = 5,
    follow: Boolean = true,
    callback: RedirectReceivedCallback = recordTo(CopyOnWriteArrayList()),
    dispatcher: Dispatcher = Dispatcher(),
  ): OkHttpClient =
    RedirectInterceptor.addRedirectInterceptor(
      OkHttpClient.Builder().followRedirects(false).dispatcher(dispatcher),
      maxRedirects,
      follow,
      callback,
    ).addInterceptor(server).build()

  private fun get(url: String) = Request.Builder().url(url).build()

  private fun recordTo(locations: MutableList<String>) =
    object : RedirectReceivedCallback {
      override fun onRedirectReceived(response: Response, location: String) {
        locations.add(location)
      }
    }

  /** /r/0 redirects to /r/1 and so on, /r/[redirects] answers */
  private fun chain(redirects: Int): Array<Pair<String, Answer>> =
    Array(redirects + 1) { index ->
      val answer = if (index < redirects) Answer(302, "https://immich.example/r/${index + 1}") else Answer(200)
      "https://immich.example/r/$index" to answer
    }

  private fun assertThrows(block: () -> Unit): IOException {
    try {
      block()
    } catch (error: IOException) {
      return error
    }
    fail("no IOException")
    throw AssertionError()
  }

  private class Outcome(val response: Response?, val failure: IOException?)

  /** Sends [request] with enqueue, as package:ok_http does, and waits until the dispatcher threads are gone */
  private fun enqueue(server: FakeServer, request: Request): Outcome {
    val threads = CopyOnWriteArrayList<Thread>()
    val factory = ThreadFactory { runnable -> Thread(runnable, "test dispatcher").also { threads.add(it) } }
    val executor = ThreadPoolExecutor(0, Int.MAX_VALUE, 1, TimeUnit.SECONDS, SynchronousQueue(), factory)
    val done = CountDownLatch(1)
    val received = AtomicReference<Response?>()
    val failure = AtomicReference<IOException?>()
    client(server, dispatcher = Dispatcher(executor)).newCall(request).enqueue(
      object : Callback {
        override fun onResponse(call: Call, response: Response) {
          response.close()
          received.set(response)
          done.countDown()
        }

        override fun onFailure(call: Call, e: IOException) {
          failure.set(e)
          done.countDown()
        }
      },
    )
    assertTrue(done.await(10, TimeUnit.SECONDS))
    // An exception OkHttp rethrows reaches the uncaught exception handler as its thread ends
    executor.shutdown()
    assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
    threads.forEach { it.join(10_000) }
    return Outcome(received.get(), failure.get())
  }

  private class Answer(val code: Int, val location: String? = null, val body: String = "")

  private class Seen(val method: String, val url: String, val headers: Headers, val body: ByteArray?)

  /** Answers from its table (404 for any other URL), or throws [failure]; records each request and each answer body */
  private class FakeServer(vararg answers: Pair<String, Answer>, private val failure: RuntimeException? = null) :
    Interceptor {
    private val table = mapOf(*answers)
    val seen = CopyOnWriteArrayList<Seen>()
    val bodies = CopyOnWriteArrayList<TrackedBody>()

    fun urls() = seen.map { it.url }

    override fun intercept(chain: Interceptor.Chain): Response {
      failure?.let { throw it }
      val request = chain.request()
      val bytes = request.body?.let { body -> Buffer().also { body.writeTo(it) }.readByteArray() }
      seen.add(Seen(request.method, request.url.toString(), request.headers, bytes))
      val answer = table[request.url.toString()] ?: Answer(404)
      val body = TrackedBody(answer.body).also { bodies.add(it) }
      val builder = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(answer.code)
        .message("Fake")
        .body(body)
      answer.location?.let { builder.header("Location", it) }
      return builder.build()
    }
  }

  private class TrackedBody(text: String) : ResponseBody() {
    private val buffer = Buffer().writeUtf8(text)

    @Volatile
    var closed = false

    override fun contentType(): MediaType? = null

    override fun contentLength() = buffer.size

    override fun source(): BufferedSource = buffer

    override fun close() {
      closed = true
      buffer.clear()
    }
  }

  /** A body that can be read once, as StreamingRequestBody of ok_http: a second read sends nothing */
  private class OneShotBody(private val bytes: ByteArray) : RequestBody() {
    val writes = AtomicInteger()

    override fun contentType(): MediaType? = null

    override fun contentLength() = bytes.size.toLong()

    override fun isOneShot() = true

    override fun writeTo(sink: BufferedSink) {
      if (writes.getAndIncrement() == 0) {
        sink.write(bytes)
      }
    }
  }
}
