// Lab stress test of crash family F2 of release 44: a SIGSEGV in libdartjni under globalEnv_CallObjectMethod while
// package:ok_http sends a request (Play P1 to P3, Meta M6). The likely cause is the JNI global reference of a call's
// receiver deleted by its Dart finalizer while the call runs: a garbage collection of the isolate group in that
// window. This test makes such collections frequent while requests run, Android only, by hand on an emulator (never
// in the CI, which has none, and never on a device of the owner):
//
//   adb -s emulator-5554 shell setprop debug.checkjni 1
//   flutter test integration_test/ok_http_receiver_stress_test.dart -d emulator-5554 --flavor phone
//
// With CheckJNI, a deleted or reused global reference no longer decodes silently to null: ART aborts with
// "JNI DETECTED ERROR IN APPLICATION" naming the reference and the JNI function (CallObjectMethodV, called from
// globalEnv_CallObjectMethod). To see the cause, run it once on the copy of ok_http before the fix
// (git checkout 32e94b33b4 -- packages/ok_http/lib, then git checkout HEAD -- packages/ok_http/lib to come back): the
// expected result there is that abort in logcat; with the fix the test completes. A pass of the copy before the fix
// does not disprove the cause, since the window is short: raise the counts below before concluding.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:ok_http/ok_http.dart';

/// Requests sent by the main isolate, as the app's root isolates send theirs
const _requests = 5000;

/// Requests sent at once by the main isolate
const _concurrency = 8;

/// Isolates that each make one first request: every binding method looks its method ID up on its first call in an
/// isolate, an allocation inside the window of its receiver
const _freshIsolates = 200;

/// Isolates of the group that allocate without pause, so that collections of the shared heap keep coming
const _allocators = 3;

const _bodySize = 16 * 1024;
const _echoSize = 3000;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ok_http keeps its JNI references through collections of the isolate group',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) => unawaited(_serve(request)));
      final base = 'http://127.0.0.1:${server.port}';
      final allocators = [for (var i = 0; i < _allocators; ++i) await Isolate.spawn(_allocate, i)];
      final failures = <String>[];
      var answered = 0;
      var aborted = 0;
      final client = OkHttpClient();
      try {
        var next = 0;
        Future<void> sendAll() async {
          while (next < _requests) {
            final index = next++;
            try {
              if (await _send(client, base, index)) {
                answered++;
              } else {
                aborted++;
              }
            } catch (error) {
              failures.add('request $index: $error');
            }
          }
        }

        var started = 0;
        var fresh = 0;
        Future<void> runFresh() async {
          while (started < _freshIsolates) {
            started++;
            final status = await _inFreshIsolate('$base/ok');
            if (status == 200) {
              fresh++;
            } else {
              failures.add('fresh isolate: status $status');
            }
          }
        }

        await Future.wait([for (var i = 0; i < _concurrency; ++i) sendAll(), for (var i = 0; i < 4; ++i) runFresh()]);

        expect(failures, isEmpty, reason: failures.take(10).join('\n'));
        expect(answered + aborted, _requests);
        expect(fresh, _freshIsolates);
      } finally {
        client.close();
        for (final isolate in allocators) {
          isolate.kill(priority: Isolate.immediate);
        }
        await subscription.cancel();
        await server.close(force: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// Sends request [index] of the mix the app sends: a download, a redirect, a body in one piece, a streamed body, an
/// abort. True when answered as expected, false when aborted; throws on anything else
Future<bool> _send(http.Client client, String base, int index) async {
  switch (index % 5) {
    case 0:
      final response = await client.get(Uri.parse('$base/ok'), headers: {'x-index': '$index'});
      _check(response.statusCode == 200 && response.bodyBytes.length == _bodySize, 'download $index');
    case 1:
      final response = await client.get(Uri.parse('$base/redirect'));
      _check(response.statusCode == 200 && response.bodyBytes.length == _bodySize, 'redirect $index');
    case 2:
      final response = await client.post(Uri.parse('$base/echo'), body: Uint8List(_echoSize));
      _check(response.statusCode == 200 && response.bodyBytes.length == _echoSize, 'body $index');
    case 3:
      final request = http.StreamedRequest('POST', Uri.parse('$base/echo'))..contentLength = _echoSize;
      final sent = client.send(request);
      for (var part = 0; part < 3; ++part) {
        request.sink.add(Uint8List(_echoSize ~/ 3));
      }
      unawaited(request.sink.close());
      final response = await http.Response.fromStream(await sent);
      _check(response.statusCode == 200 && response.bodyBytes.length == _echoSize, 'streamed body $index');
    default:
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('$base/slow'),
        abortTrigger: Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      try {
        final response = await http.Response.fromStream(await client.send(request));
        _check(response.statusCode == 200, 'abort $index');
      } on http.RequestAbortedException {
        return false;
      }
  }
  return true;
}

void _check(bool ok, String what) {
  if (!ok) {
    throw StateError('unexpected answer to $what');
  }
}

/// Runs [_firstRequest] in a new isolate; a top level function, so that the closure sent holds [url] only
Future<int> _inFreshIsolate(String url) => Isolate.run(() => _firstRequest(url));

/// The first request of a fresh isolate, through a client of its own
Future<int> _firstRequest(String url) async {
  final client = OkHttpClient();
  try {
    final response = await client.get(Uri.parse(url));
    return response.bodyBytes.length == _bodySize ? response.statusCode : -1;
  } finally {
    client.close();
  }
}

/// Allocates forever, keeping a ring of recent lists so that some reach the old generation too
void _allocate(int seed) {
  final ring = List<List<int>?>.filled(4096, null);
  var count = seed;
  while (true) {
    ring[count % ring.length] = List<int>.filled(256, count);
    count++;
  }
}

Future<void> _serve(HttpRequest request) async {
  final response = request.response;
  try {
    switch (request.uri.path) {
      case '/ok':
        response.headers
          ..set('x-lab', 'ok_http receivers')
          ..set('cache-control', 'no-store');
        response.add(Uint8List(_bodySize));
      case '/redirect':
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:${request.connectionInfo!.localPort}/ok');
        await request.drain<void>();
      case '/echo':
        final bytes = BytesBuilder(copy: false);
        await request.forEach(bytes.add);
        response.add(bytes.takeBytes());
      case '/slow':
        await Future<void>.delayed(const Duration(milliseconds: 50));
        response.add(Uint8List(_bodySize));
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  } catch (_) {
    // An aborted request closes its connection before the answer: nothing to do
  }
}
