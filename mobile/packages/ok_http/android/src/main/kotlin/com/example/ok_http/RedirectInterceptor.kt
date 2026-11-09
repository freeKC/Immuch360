// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// To cause a request failure [with a suitable message] due to too many redirects,
// we need to throw an IOException. This cannot be done using Dart JNI bindings,
// which lead to a deadlock and eventually a `java.net.SocketTimeoutException`.
// https://github.com/dart-lang/native/issues/561

package com.example.ok_http

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/**
 * Callback interface utilized by the [RedirectInterceptor].
 *
 * Allows Dart code to operate upon the intermediate redirect responses.
 */
interface RedirectReceivedCallback {
    // Immuch360: [location] is the URL the redirect is followed to, resolved against the request, no longer the raw
    // header. The signature is bound by the JNI bindings and must not change (see IMMUCH360-NOTE.md)
    fun onRedirectReceived(response: Response, location: String)
}


class RedirectInterceptor {
    companion object {

        /** Immuch360: the most redirects followed for one request, OkHttp's own limit, whatever the caller asks */
        const val MAX_REDIRECTS = 20

        // Immuch360: the most distinct unusual redirects reported in a process, so that the set below stays small
        private const val MAX_REPORTS = 64

        /**
         * Immuch360: told of the unusual redirects, in a text that carries no query string and no user info: a
         * relative `Location` that was resolved, a `Location` that is not an http or https URL, a streamed body that
         * stopped a redirect, an `Authorization` header left behind (which explains a 401 that follows). Once per
         * process for each host of the request, status and kind. Called on an OkHttp thread; null by default, so that
         * the plugin needs nothing of the app (the app sets it, the tests too).
         */
        @Volatile
        var onUnusualRedirect: ((String) -> Unit)? = null

        private val reported = ConcurrentHashMap.newKeySet<String>()

        /**
         * Adds a redirect interceptor to the OkHttpClient.Builder
         *
         * Immuch360: the loop follows OkHttp's own rules (RetryAndFollowUpInterceptor of OkHttp 4.12) but for the
         * method of 301 and 302 and for `Authorization` on an upgrade to https. A relative `Location` is resolved
         * against the request (RFC 9110 section 10.2.2): the raw header given to `Request.Builder.url` threw an
         * IllegalArgumentException on OkHttp's dispatcher thread, which ended the app. A missing `Location`, or one
         * that is not an http or https URL, is not followed: the caller gets the redirect. 303 turns any method but
         * GET, HEAD and PROPFIND into a GET without body; 300, 301, 302, 307 and 308 keep the method and the body, as
         * before and as RFC 9110 allows (OkHttp turns 301 and 302 into a GET, which would lose a sign in sent to
         * http:// behind a redirect to https://). A one-shot body (the streamed uploads, [StreamingRequestBody]) is
         * never sent twice: the caller gets the redirect.
         * `Authorization` follows to the same host on the same scheme and port, and on an upgrade from http to https
         * of the same host (port 80 to 443, or the same port); it is dropped on another host or port and on a
         * downgrade from https to http, a drop told to [onUnusualRedirect]. Any RuntimeException of the chain becomes
         * an IOException, which the caller gets as a failed request: OkHttp rethrows anything else on its dispatcher
         * thread, and the app ends.
         *
         * @param clientBuilder The `OkHttpClient.Builder` to add the interceptor to
         * @param maxRedirects The maximum number of redirects to follow (Immuch360: 0 to [MAX_REDIRECTS])
         * @param followRedirects Whether to follow redirects
         *
         * @return OkHttpClient.Builder
         */
        fun addRedirectInterceptor(
            clientBuilder: OkHttpClient.Builder,
            maxRedirects: Int,
            followRedirects: Boolean,
            redirectCallback: RedirectReceivedCallback,
        ): OkHttpClient.Builder {
            val limit = maxRedirects.coerceIn(0, MAX_REDIRECTS)
            return clientBuilder.addInterceptor(Interceptor { chain ->
                // Immuch360: the response that is open, closed when a RuntimeException ends the request
                var unclosed: Response? = null
                try {
                    var req = chain.request()
                    var response = chain.proceed(req)
                    unclosed = response
                    var redirectCount = 0

                    while (response.isRedirect && followRedirects) {
                        val next = followUp(req, response) ?: break
                        if (redirectCount >= limit) {
                            response.close()
                            throw IOException("Redirect limit exceeded")
                        }

                        redirectCallback.onRedirectReceived(response, next.url.toString())

                        response.close()
                        unclosed = null
                        req = next
                        response = chain.proceed(req)
                        unclosed = response
                        redirectCount++
                    }

                    response
                } catch (error: RuntimeException) {
                    try {
                        unclosed?.close()
                    } catch (_: RuntimeException) {
                        // A response without a body cannot be closed, and has nothing to release
                    }
                    throw IOException("Request failed: $error", error)
                }
            })
        }

        /** Immuch360: the request that follows the redirect [response] to [request], null when it is not followed */
        private fun followUp(request: Request, response: Response): Request? {
            val location = response.header("Location") ?: return null
            val url = request.url.resolve(location)
            if (url == null) {
                report(request, response, "unusable") {
                    "not followed: its Location ${withoutQuery(location)} is not an http or https URL"
                }
                return null
            }
            val builder = request.newBuilder().url(url)
            val method = request.method
            if (response.code == 303 && method != "GET" && method != "HEAD" && method != "PROPFIND") {
                // RFC 9110 section 15.4.4: the answer is fetched with a GET, the body stays behind
                builder.method("GET", null)
                    .removeHeader("Transfer-Encoding")
                    .removeHeader("Content-Length")
                    .removeHeader("Content-Type")
            } else if (request.body?.isOneShot() == true) {
                // The first request has read the body: a second one would go out empty or cut
                report(request, response, "one-shot") {
                    "to ${describe(url)} not followed: the body was streamed and cannot be sent again"
                }
                return null
            }
            if (request.header("Authorization") != null && !keepsAuthorization(request.url, url)) {
                builder.removeHeader("Authorization")
                report(request, response, "authorization") {
                    "to ${describe(url)}: Authorization not sent to another host, port or scheme"
                }
            }
            if (location.toHttpUrlOrNull() == null) {
                report(request, response, "relative") { "to a relative Location, resolved to ${describe(url)}" }
            }
            return builder.build()
        }

        /**
         * Immuch360: whether the credentials of a request to [from] go on to [to]. OkHttp keeps them on the same
         * scheme, host and port only. An upgrade from http to https of the same host keeps them too, so that a server
         * URL in http behind a redirect to https still signs in: port 80 to 443, or the same port on both. Another
         * host, another port, and a downgrade from https to http drop them.
         */
        private fun keepsAuthorization(from: HttpUrl, to: HttpUrl): Boolean {
            if (to.host != from.host) {
                return false
            }
            if (to.scheme == from.scheme) {
                return to.port == from.port
            }
            val upgrade = from.scheme == "http" && to.scheme == "https"
            return upgrade && (to.port == from.port || (from.port == 80 && to.port == 443))
        }

        private fun report(request: Request, response: Response, kind: String, what: () -> String) {
            val hook = onUnusualRedirect ?: return
            if (reported.size >= MAX_REPORTS || !reported.add("${request.url.host} ${response.code} $kind")) {
                return
            }
            try {
                hook("Redirect ${response.code} of ${request.method} ${describe(request.url)} ${what()}")
            } catch (_: RuntimeException) {
                // A report never fails the request
            }
        }

        /** Scheme, host, port when it is not the default one, and path: no user info, no query string */
        private fun describe(url: HttpUrl): String {
            val host = if (url.host.contains(':')) "[${url.host}]" else url.host
            val port = if (url.port == HttpUrl.defaultPort(url.scheme)) "" else ":${url.port}"
            return "${url.scheme}://$host$port${url.encodedPath}"
        }

        /** [location] without its query string, fragment and user info, at most 100 characters */
        private fun withoutQuery(location: String): String {
            var text = location.substringBefore('?').substringBefore('#')
            val authority = text.indexOf("//")
            if (authority >= 0) {
                val end = text.indexOf('/', authority + 2).let { if (it < 0) text.length else it }
                val at = text.lastIndexOf('@', end - 1)
                if (at >= authority + 2) {
                    text = text.substring(0, authority + 2) + text.substring(at + 1)
                }
            }
            return if (text.length > 100) text.take(100) + "..." else text
        }
    }
}
