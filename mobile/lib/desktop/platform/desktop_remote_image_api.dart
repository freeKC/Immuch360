import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/network/desktop_http_stack.dart';
import 'package:immich_mobile/desktop/network/remote_image_cache.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopRemoteImageApi');

/// The server answered an image request with an error status
class RemoteImageHttpException implements Exception {
  const RemoteImageHttpException(this.statusCode, this.reasonPhrase);

  final int statusCode;
  final String? reasonPhrase;

  @override
  String toString() => 'HTTP $statusCode: ${reasonPhrase ?? ''}';
}

/// RemoteImageApi on the computers. The phones fetch and decode the server's images natively; here the answer is the
/// encoded image, {pointer, length} in a buffer of `package:ffi`'s malloc, which RemoteImageRequest already accepts
/// ("Android falls back to encoded data") and frees with malloc.free, the engine decoding it at the requested size.
/// The image comes through the app's HTTP stack (custom headers, session cookie, client certificate) and is kept in
/// RemoteImageCache. A cancelled request answers null, as the native ones do.
class DesktopRemoteImageApi implements RemoteImageApi {
  DesktopRemoteImageApi({this._stack, RemoteImageCache? cache, DateTime Function()? clock})
    : _cacheOverride = cache,
      _clock = clock ?? DateTime.now;

  final DesktopHttpStack? _stack;
  final RemoteImageCache? _cacheOverride;
  final DateTime Function() _clock;

  /// The cancel trigger of each request being served
  final _requests = <int, Completer<void>>{};

  /// The addresses checked in the background, so that a list scrolled twice asks once
  final _revalidating = <String>{};

  // The app's stack and cache are read at the call: this object is made when the platform provider loads
  http.Client get _client => (_stack ?? DesktopHttpStack.instance).client;

  RemoteImageCache get _cache => _cacheOverride ?? RemoteImageCache.instance;

  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  /// [preferEncoded], [width] and [height] ask the phones for decoded pixels at a size; the computers always answer
  /// the encoded image, which the loader decodes at that size
  @override
  Future<Map<String, int>?> requestImage(
    String url, {
    required int requestId,
    required bool preferEncoded,
    int? width,
    int? height,
  }) async {
    final cancel = Completer<void>();
    _requests[requestId] = cancel;
    try {
      return await _load(url, cancel);
    } on http.RequestAbortedException {
      return null;
    } finally {
      _requests.remove(requestId);
    }
  }

  @override
  Future<void> cancelRequest(int requestId) async {
    final cancel = _requests.remove(requestId);
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete();
    }
  }

  /// The bytes freed
  @override
  Future<int> clearCache() => _cache.clear();

  Future<Map<String, int>?> _load(String url, Completer<void> cancel) async {
    final cache = _cache;
    final key = cache.keyOf(url);
    final cached = await cache.lookup(key);
    final now = _clock();
    if (cached != null && cached.meta.isFresh(now)) {
      final hit = await _deliverCached(cached, cancel);
      if (hit != null || cancel.isCompleted) {
        return hit;
      }
    } else if (cached != null && cached.meta.canServeWhileRevalidating(now)) {
      final hit = await _deliverCached(cached, cancel);
      if (hit != null || cancel.isCompleted) {
        _revalidateInBackground(url, key, cached);
        return hit;
      }
    }
    if (cancel.isCompleted) {
      return null;
    }
    try {
      return await _fetch(url, key, cached, cancel: cancel);
    } on http.RequestAbortedException {
      rethrow;
    } catch (error) {
      // A server that cannot be reached or fails (not one that refuses or lost the image) leaves the stored copy in
      // use for as long as stale-if-error allows
      final serverDown = error is! RemoteImageHttpException || error.statusCode >= 500;
      if (cached != null && serverDown && cached.meta.canServeOnError(_clock()) && !cancel.isCompleted) {
        final hit = await _deliverCached(cached, cancel);
        if (hit != null) {
          return hit;
        }
      }
      rethrow;
    }
  }

  Future<Map<String, int>?> _deliverCached(CachedImage cached, Completer<void> cancel) async {
    final body = await _cache.readBody(cached);
    if (body == null) {
      return null;
    }
    if (cancel.isCompleted) {
      malloc.free(body.pointer);
      return null;
    }
    return {'pointer': body.pointer.address, 'length': body.length};
  }

  void _revalidateInBackground(String url, String key, CachedImage cached) {
    if (!_revalidating.add(key)) {
      return;
    }
    unawaited(
      _fetch(url, key, cached, deliver: false)
          .then((_) {}, onError: (Object error) => _log.fine('A stored image was not checked again: $error'))
          .whenComplete(() => _revalidating.remove(key)),
    );
  }

  /// Asks the server, conditionally when a copy is stored, and keeps what it answers. With [deliver], the image in a
  /// malloc buffer; without, null once the cache is up to date.
  Future<Map<String, int>?> _fetch(
    String url,
    String key,
    CachedImage? cached, {
    Completer<void>? cancel,
    bool deliver = true,
  }) async {
    final request = http.AbortableRequest('GET', Uri.parse(url), abortTrigger: cancel?.future);
    final etag = cached?.meta.etag;
    final lastModified = cached?.meta.lastModified;
    if (etag != null) {
      request.headers['if-none-match'] = etag;
    }
    if (lastModified != null) {
      request.headers['if-modified-since'] = lastModified;
    }
    final response = await _client.send(request);
    final now = _clock();

    if (response.statusCode == 304 && cached != null) {
      await response.stream.drain<void>();
      final meta = cached.meta.revalidated(response.headers, now);
      await _cache.updateMeta(cached, meta);
      if (!deliver) {
        return null;
      }
      final hit = await _deliverCached(cached.withMeta(meta), cancel ?? Completer());
      if (hit == null && !(cancel?.isCompleted ?? false)) {
        // The stored file went away between the question and the answer: ask for the whole image
        return _fetch(url, key, null, cancel: cancel);
      }
      return hit;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>().catchError((_) {});
      throw RemoteImageHttpException(response.statusCode, response.reasonPhrase);
    }

    final meta = CacheMeta.fromResponse(response.headers, now);
    final writer = meta == null || !meta.isReusable ? null : await _cache.begin(key, meta);
    final buffer = deliver ? _NativeBuffer(response.contentLength) : null;
    try {
      await for (final chunk in response.stream) {
        buffer?.add(chunk);
        writer?.add(chunk);
      }
    } catch (_) {
      buffer?.free();
      await writer?.discard();
      rethrow;
    }
    if (cancel?.isCompleted ?? false) {
      buffer?.free();
      await writer?.discard();
      return null;
    }
    if (buffer != null && buffer.length == 0) {
      buffer.free();
      await writer?.discard();
      throw RemoteImageHttpException(response.statusCode, 'Empty response body');
    }
    // The answer does not wait for the disk
    unawaited(writer?.commit());
    if (buffer == null) {
      return null;
    }
    return {'pointer': buffer.address, 'length': buffer.length};
  }
}

/// A growing buffer of malloc memory, handed to the image loader, which frees it
class _NativeBuffer {
  _NativeBuffer(int? expected)
    : _capacity = expected != null && expected > 0 && expected <= _largestUpFront ? expected : _initial {
    _pointer = malloc<Uint8>(_capacity);
  }

  static const _initial = 64 * 1024;

  /// Content-Length comes from the server; beyond this the buffer grows as the bytes arrive
  static const _largestUpFront = 128 * 1024 * 1024;

  late Pointer<Uint8> _pointer;
  int _capacity;
  int length = 0;

  int get address => _pointer.address;

  void add(List<int> chunk) {
    final needed = length + chunk.length;
    if (needed > _capacity) {
      final capacity = math.max(needed, _capacity * 2);
      final grown = malloc<Uint8>(capacity);
      grown.asTypedList(length).setAll(0, _pointer.asTypedList(length));
      malloc.free(_pointer);
      _pointer = grown;
      _capacity = capacity;
    }
    _pointer.asTypedList(_capacity).setRange(length, needed, chunk);
    length = needed;
  }

  void free() => malloc.free(_pointer);
}
