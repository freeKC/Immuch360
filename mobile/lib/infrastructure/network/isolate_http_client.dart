// An http.Client whose requests run in a worker isolate, for the servers a film streams from (Plex): the TLS of the
// connections, the reading of the bodies and the timers of dart:io stay off the isolate that runs the app's UI.
//
// On Android the UI isolate runs on the main thread of the app, which also draws the frames while a video plays. On a
// Samsung S24 (14 November 2026) a Plex film read through the media bridge came at 4 to 8 Mbit/s while the phone read
// the same file at 41 Mbit/s outside the app: dart:io decrypts a TLS body 8 KiB at a time, each pass a few turns of
// the event loop of the isolate that reads it, and with that loop busy at 60 % the turns may come late (a likely cause,
// not yet measured on the phone: the PC bench does not reproduce the 4 to 8 Mbit/s). Here the worker takes those
// turns; the isolate of the app sees each answer's head, then its body in batches of up to [batchSize]
// bytes, a few dozen messages a second instead of over a thousand. The worker joins the pieces of a batch into one
// buffer (one copy there), which crosses to the app without a copy (TransferableTypedData). Each batch still costs the
// app's isolate one turn (the message, the add to the body, its acknowledgement), and a reader that joins batches
// (HttpRangeReader joins those of one range) copies them once more there.
//
// The client behaves as IOClient does: an http.Abortable request stops at once when its trigger completes (before its
// answer, or in the middle of its body, with an http.RequestAbortedException), the errors are those of IOClient, and a
// body is read only as fast as it is taken (at most [windowBytes] wait for their reader).

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Makes the dart:io client of an [IsolateHttpClient], in the worker isolate: it must not hold anything an isolate
/// cannot send (a SecurityContext, an open socket), so make those inside it
typedef HttpClientMaker = HttpClient Function();

/// An http.Client that sends its requests from a worker isolate shared by all such clients, see the top of the file
class IsolateHttpClient extends http.BaseClient {
  IsolateHttpClient(HttpClientMaker make) : _id = _Hub.instance.openClient(make);

  /// Most bytes of a body handed over at once
  static const batchSize = 256 * 1024;

  /// Longest wait of the bytes of a body that trickles before they are handed over
  static const batchDelay = Duration(milliseconds: 20);

  /// Bytes of a body handed over and not yet taken by its reader, past which the worker stops reading it: the largest
  /// read of the media bridge (4 MiB), so that the worker keeps reading through a late turn of the app's isolate of
  /// about a second at 40 Mbit/s. Counted in batches (4) it was about 80 ms there, the batches of a link of that rate
  /// being about 100 KB (those of [batchDelay]), and the socket paused at each late frame (review of 14 November 2026)
  static const windowBytes = 4 * 1024 * 1024;

  final int _id;
  bool _closed = false;

  /// The batches of body handed over by the worker since the start, all clients together (for the tests and benches)
  static int get batchesReceived => _Hub.instance.batches;

  /// The bytes of body handed over by the worker since the start, all clients together (for the tests and benches)
  static int get bytesReceived => _Hub.instance.bytes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('HTTP request failed. Client is already closed.', request.url);
    }
    final body = await request.finalize().toBytes();
    return _Hub.instance.send(_id, request, body);
  }

  /// Closes the connections of this client, the requests under way failing as with IOClient
  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _Hub.instance.closeClient(_id);
  }
}

// The messages, lists whose first item is their kind. To the worker: open (client id, maker), close (client id), send
// (client id, request id, method, url, headers, follow redirects, most redirects, persistent connection, body), ack,
// abort and cancel (request id). From the worker: head (request id, status, length, reason, headers, is redirect,
// persistent connection, url), data (request id, bytes), error (request id, error, stack trace), done (request id).
const _open = 0;
const _close = 1;
const _send = 2;
const _ack = 3;
const _abort = 4;
const _cancel = 5;
const _head = 10;
const _data = 11;
const _error = 12;
const _done = 13;

/// The side of the app's isolate: the worker, started at the first client, and the requests under way
class _Hub {
  _Hub._();

  static final instance = _Hub._();

  RawReceivePort? _port;
  SendPort? _worker;

  /// The messages for a worker that is starting, sent once it is there
  List<List<Object?>>? _queued;
  int _nextClient = 0;
  int _nextRequest = 0;
  int batches = 0;
  int bytes = 0;
  final _requests = <int, _Request>{};

  /// The makers of the open clients, opened again in a new worker when one failed to start
  final _makers = <int, HttpClientMaker>{};
  bool _lost = false;

  int openClient(HttpClientMaker make) {
    final id = _nextClient++;
    _makers[id] = make;
    _post([_open, id, make]);
    return id;
  }

  void closeClient(int id) {
    _makers.remove(id);
    _post([_close, id]);
  }

  Future<http.StreamedResponse> send(int client, http.BaseRequest request, Uint8List body) {
    final id = _nextRequest++;
    final pending = _Request(this, id, request);
    _requests[id] = pending;
    _keepAlive();
    _post([
      _send,
      client,
      id,
      request.method,
      request.url.toString(),
      Map<String, String>.of(request.headers),
      request.followRedirects,
      request.maxRedirects,
      request.persistentConnection,
      body,
    ]);
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then<void>((_) => pending.abort(), onError: (Object _) => pending.abort()));
    }
    return pending.head.future;
  }

  void _post(List<Object?> message) {
    final worker = _worker;
    if (worker != null) {
      worker.send(message);
      return;
    }
    final queued = _queued;
    if (queued != null) {
      queued.add(message);
      return;
    }
    _queued = [
      if (_lost)
        for (final MapEntry(:key, :value) in _makers.entries)
          if (message[0] != _open || message[1] != key) [_open, key, value],
      message,
    ];
    _lost = false;
    unawaited(_start());
  }

  Future<void> _start() async {
    final port = _port ??= RawReceivePort(_receive, 'http worker answers');
    port.keepIsolateAlive = true;
    try {
      await Isolate.spawn(_workerMain, port.sendPort, debugName: 'http worker', errorsAreFatal: false);
    } catch (error, stackTrace) {
      // No worker: the requests waiting fail, the next one tries again
      final queued = _queued ?? const [];
      _queued = null;
      _lost = true;
      for (final message in queued) {
        if (message[0] == _send) {
          _requests[message[2]! as int]?.fail(error, stackTrace);
        }
      }
      _keepAlive();
    }
  }

  void _receive(Object? message) {
    if (message is SendPort) {
      _worker = message;
      final queued = _queued ?? const [];
      _queued = null;
      for (final waiting in queued) {
        message.send(waiting);
      }
      _keepAlive();
      return;
    }
    final parts = message! as List<Object?>;
    final request = _requests[parts[1]! as int];
    if (request == null) {
      // Ended here already (aborted, cancelled): what the worker still sent for it is dropped
      return;
    }
    switch (parts[0]) {
      case _head:
        request.onHead(parts);
      case _data:
        batches++;
        request.onData(parts[2]! as TransferableTypedData);
      case _error:
        request.fail(parts[2]!, StackTrace.fromString(parts[3]! as String));
      case _done:
        request.onDone();
    }
  }

  void _ended(_Request request) {
    _requests.remove(request.id);
    _keepAlive();
  }

  /// The port keeps the app's isolate alive while a request waits for the worker, and only then (the tests end)
  void _keepAlive() => _port?.keepIsolateAlive = _requests.isNotEmpty || _queued != null;
}

/// A request under way, on the side of the app's isolate
class _Request {
  _Request(this._hub, this.id, this._request);

  final _Hub _hub;
  final int id;
  final http.BaseRequest _request;
  final head = Completer<http.StreamedResponse>();
  StreamController<List<int>>? _body;

  /// Batches received while the reader of the body did not take them: their acknowledgement waits for it
  int _owed = 0;
  bool _ended = false;

  void onHead(List<Object?> parts) {
    if (_ended || head.isCompleted) {
      return;
    }
    // Closed at the end of the body, its abort or its cancel
    // ignore: close_sinks
    final body = _body = StreamController<List<int>>(
      onListen: _pay,
      onResume: _pay,
      onCancel: () {
        if (!_ended) {
          _hub._post([_cancel, id]);
          _end();
        }
      },
    );
    head.complete(
      _Response(
        body.stream,
        parts[2]! as int,
        contentLength: parts[3] as int?,
        reasonPhrase: parts[4] as String?,
        headers: parts[5]! as Map<String, String>,
        isRedirect: parts[6]! as bool,
        persistentConnection: parts[7]! as bool,
        url: Uri.parse(parts[8]! as String),
        request: _request,
      ),
    );
  }

  void onData(TransferableTypedData data) {
    final body = _body;
    if (body == null || _ended) {
      return;
    }
    final bytes = data.materialize().asUint8List();
    _hub.bytes += bytes.length;
    body.add(bytes);
    if (body.hasListener && !body.isPaused) {
      _hub._post([_ack, id]);
    } else {
      _owed++;
    }
  }

  /// The reader takes the body again: the worker may hand over what it owes
  void _pay() {
    while (_owed > 0 && !_ended) {
      _owed--;
      _hub._post([_ack, id]);
    }
  }

  void onDone() {
    if (_ended) {
      return;
    }
    _end();
    unawaited(_body?.close());
  }

  /// [error] before the answer fails the request; in the middle of the body, the body
  void fail(Object error, StackTrace stackTrace) {
    if (_ended) {
      return;
    }
    if (!head.isCompleted) {
      _end();
      head.completeError(error, stackTrace);
      return;
    }
    _body?.addError(error, stackTrace);
  }

  /// The trigger of an http.Abortable request: as IOClient, the request fails, or its body ends with the error
  void abort() {
    if (_ended) {
      return;
    }
    _end();
    _hub._post([_abort, id]);
    final error = http.RequestAbortedException(_request.url);
    if (!head.isCompleted) {
      head.completeError(error);
      return;
    }
    final body = _body;
    if (body != null && !body.isClosed) {
      body.addError(error);
      unawaited(body.close());
    }
  }

  void _end() {
    _ended = true;
    _hub._ended(this);
  }
}

/// A streamed response that tells the URL that answered, as those of IOClient do
class _Response extends http.StreamedResponse implements http.BaseResponseWithUrl {
  _Response(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}

// The worker isolate

void _workerMain(SendPort toApp) {
  final clients = <int, http.Client>{};
  final requests = <int, _WorkerRequest>{};
  final port = RawReceivePort();
  port.handler = (Object? message) {
    final parts = message! as List<Object?>;
    switch (parts[0]) {
      case _open:
        clients[parts[1]! as int] = IOClient((parts[2]! as HttpClientMaker)());
      case _close:
        clients.remove(parts[1]! as int)?.close();
      case _send:
        final id = parts[2]! as int;
        final request = _WorkerRequest(id, toApp, () => requests.remove(id));
        requests[id] = request;
        unawaited(request.start(clients[parts[1]! as int], parts));
      case _ack:
        requests[parts[1]! as int]?.ack();
      case _abort:
        requests[parts[1]! as int]?.abort();
      case _cancel:
        requests[parts[1]! as int]?.cancel();
    }
  };
  toApp.send(port.sendPort);
}

/// A request under way, in the worker: sends it, then hands its body over in batches as fast as the app takes them
class _WorkerRequest {
  _WorkerRequest(this.id, this._toApp, this._forget);

  final int id;
  final SendPort _toApp;
  final void Function() _forget;
  final _abort = Completer<void>();
  Uri? _url;
  StreamSubscription<List<int>>? _subscription;
  final _pending = <Uint8List>[];
  int _pendingBytes = 0;
  Timer? _flushTimer;

  /// The sizes of the batches handed over and not yet taken, oldest first, and their sum
  final _unacked = Queue<int>();
  int _unackedBytes = 0;

  /// A batch was due while [IsolateHttpClient.windowBytes] waited: it goes at the next acknowledgement
  bool _flushDue = false;
  bool _paused = false;
  bool _ended = false;

  Future<void> start(http.Client? client, List<Object?> parts) async {
    final url = _url = Uri.parse(parts[4]! as String);
    if (client == null) {
      _fail(http.ClientException('HTTP request failed. Client is already closed.', url), StackTrace.current);
      _end();
      return;
    }
    final request = http.AbortableRequest(parts[3]! as String, url, abortTrigger: _abort.future)
      ..headers.addAll(parts[5]! as Map<String, String>)
      ..followRedirects = parts[6]! as bool
      ..maxRedirects = parts[7]! as int
      ..persistentConnection = parts[8]! as bool
      ..bodyBytes = parts[9]! as Uint8List;
    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (error, stackTrace) {
      _fail(error, stackTrace);
      _end();
      return;
    }
    if (_ended) {
      // Cancelled or aborted while the answer came
      unawaited(response.stream.listen(null).cancel().then<void>((_) {}, onError: (Object _) {}));
      return;
    }
    final finalUrl = switch (response) {
      http.BaseResponseWithUrl(url: final answered) => answered,
      _ => url,
    };
    _toApp.send([
      _head,
      id,
      response.statusCode,
      response.contentLength,
      response.reasonPhrase,
      response.headers,
      response.isRedirect,
      response.persistentConnection,
      finalUrl.toString(),
    ]);
    _subscription = response.stream.listen(_onData, onError: _onError, onDone: _onDone);
  }

  void _onData(List<int> data) {
    final chunk = data is Uint8List ? data : Uint8List.fromList(data);
    _pending.add(chunk);
    _pendingBytes += chunk.length;
    if (_pendingBytes >= IsolateHttpClient.batchSize) {
      _flush();
    } else {
      _flushTimer ??= Timer(IsolateHttpClient.batchDelay, _flush);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    _sendPending();
    _fail(error, stackTrace);
  }

  void _onDone() {
    _subscription = null;
    if (_ended) {
      return;
    }
    _sendPending();
    _toApp.send([_done, id]);
    _end();
  }

  /// Hands over what came, unless the app did not take enough of it yet
  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_ended || _pendingBytes == 0) {
      return;
    }
    if (_unackedBytes >= IsolateHttpClient.windowBytes) {
      _flushDue = true;
      _pause();
      return;
    }
    _sendPending();
    if (_unackedBytes >= IsolateHttpClient.windowBytes) {
      _pause();
    }
  }

  void _sendPending() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_ended || _pendingBytes == 0) {
      return;
    }
    _toApp.send([_data, id, TransferableTypedData.fromList(_pending)]);
    _flushDue = false;
    _unacked.add(_pendingBytes);
    _unackedBytes += _pendingBytes;
    _pending.clear();
    _pendingBytes = 0;
  }

  void ack() {
    if (_unacked.isNotEmpty) {
      _unackedBytes -= _unacked.removeFirst();
    }
    // A batch held back goes now; one still filling waits for its size or its delay
    if (_flushDue) {
      _flush();
    }
    if (_unackedBytes < IsolateHttpClient.windowBytes && _paused) {
      _paused = false;
      _subscription?.resume();
    }
  }

  void _pause() {
    if (!_paused) {
      _paused = true;
      _subscription?.pause();
    }
  }

  void abort() {
    if (!_abort.isCompleted) {
      _abort.complete();
    }
    cancel();
  }

  void cancel() {
    if (_ended) {
      return;
    }
    _end();
    final subscription = _subscription;
    _subscription = null;
    if (subscription == null) {
      // Still waiting for the answer: stopped there
      if (!_abort.isCompleted) {
        _abort.complete();
      }
    } else {
      unawaited(subscription.cancel().then<void>((_) {}, onError: (Object _) {}));
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_ended) {
      return;
    }
    try {
      _toApp.send([_error, id, error, stackTrace.toString()]);
    } catch (_) {
      // An error the isolates cannot share: its text
      _toApp.send([_error, id, http.ClientException(error.toString(), _url), stackTrace.toString()]);
    }
  }

  void _end() {
    if (_ended) {
      return;
    }
    _ended = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _pendingBytes = 0;
    _forget();
  }
}
