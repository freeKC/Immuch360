// Lab stress test of crash family F2 of release 44: a SIGSEGV in libdartjni under globalEnv_CallObjectMethod while
// package:ok_http sends a request (Play P1 to P3, Meta M6). The likely cause is the JNI global reference of a call's
// receiver deleted by its Dart finalizer while the call runs: a garbage collection of the isolate group in that
// window. This test makes such collections frequent while requests run, Android only, on an emulator: the workflow
// immuch360-android-lab.yml runs it on one of the CI, or by hand (never on a device of the owner):
//
//   adb -s emulator-5554 shell setprop debug.checkjni 1
//   flutter test integration_test/ok_http_receiver_stress_test.dart -d emulator-5554 --flavor phone
//
// The second test sends requests whose abort races the answer, the case where upstream's onResponse threw "Future
// already completed" back to OkHttp's dispatcher thread, which ended the app (immich-app/immich#31333). Its pass is
// that the app lives: no FATAL EXCEPTION in logcat, which the workflow checks.
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

/// Requests whose abort races the answer of the local server, sent 8 at once
const _racingAborts = 3000;

const _nowSize = 512;

/// The abort triggers of the racing requests that the server fires once their answer is sent, by request index
final _abortWhenAnswered = <String, Completer<void>>{};

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

        // ignore: avoid_print
        print('OKHTTP_LAB receivers: $answered answered, $aborted aborted, $fresh isolates, ${failures.length} failed');
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

  test(
    'an abort that races the answer never throws back into the thread of OkHttp',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) => unawaited(_serve(request)));
      final base = 'http://127.0.0.1:${server.port}';
      final failures = <String>[];
      var answered = 0;
      var aborted = 0;
      final client = OkHttpClient();
      try {
        var next = 0;
        Future<void> sendAll() async {
          while (next < _racingAborts) {
            final index = next++;
            try {
              if (await _sendRacing(client, base, index)) {
                answered++;
              } else {
                aborted++;
              }
            } catch (error) {
              failures.add('request $index: $error');
            }
          }
        }

        await Future.wait([for (var i = 0; i < _concurrency; ++i) sendAll()]);

        // ignore: avoid_print
        print('OKHTTP_LAB racing aborts: $answered answered, $aborted aborted, ${failures.length} failed');
        expect(failures, isEmpty, reason: failures.take(10).join('\n'));
        expect(answered + aborted, _racingAborts);
        expect(aborted, greaterThan(0));
      } finally {
        client.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

/// Sends racing request [index] to /now, aborted by a trigger already completed, by one completed after a turn of
/// the event loop, or by one the server completes from 0 to 5 ms after the answer is sent, so that the abort lands on
/// either side of OkHttp's onResponse. True when answered, false when aborted; throws on anything else
Future<bool> _sendRacing(http.Client client, String base, int index) async {
  final key = '$index';
  final Future<void> trigger;
  switch (index % 3) {
    case 0:
      trigger = Future<void>.value();
    case 1:
      trigger = Future<void>.delayed(Duration.zero);
    default:
      trigger = (_abortWhenAnswered[key] = Completer<void>()).future;
  }
  final request = http.AbortableRequest('GET', Uri.parse('$base/now'), abortTrigger: trigger)..headers['x-abort'] = key;
  try {
    final response = await http.Response.fromStream(await client.send(request));
    _check(response.statusCode == 200 && response.bodyBytes.length == _nowSize, 'racing abort $index');
    return true;
  } on http.RequestAbortedException {
    return false;
  } finally {
    // A request that ended before the server fired its trigger leaves the trigger behind
    _abortWhenAnswered.remove(key)?.complete();
  }
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
      case '/now':
        response.add(Uint8List(_nowSize));
        await response.close();
        final key = request.headers.value('x-abort');
        final lag = (int.tryParse(key ?? '') ?? 0) ~/ 3 % 21;
        await Future<void>.delayed(Duration(microseconds: 250 * lag));
        _abortWhenAnswered.remove(key)?.complete();
        return;
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  } catch (_) {
    // An aborted request closes its connection before the answer: nothing to do
  }
}
