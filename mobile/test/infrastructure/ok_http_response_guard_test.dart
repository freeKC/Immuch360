import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
// The guard alone, which has no JNI in it: the client around it needs Android
import 'package:ok_http/src/response_guard.dart';

/// Guards of the response callback of the copy of ok_http in packages/ok_http (review of the release 44 crash lot).
/// OkHttp's onResponse is a synchronous proxy of package:jni: an error of its Dart side goes back to OkHttp's
/// dispatcher thread, which throws it again, and the app ends. Upstream completed the request there without checking
/// it, so a response that came after an abort threw "Future already completed" (immich-app/immich#31333). The guard
/// must never throw, and the request must end with an error the caller sees.
void main() {
  final url = Uri.parse('https://immich.example/api/assets');

  group('guardResponseCallback', () {
    late Completer<StreamedResponse> completer;
    late List<String> steps;
    late List<ClientException> told;
    late StreamController<List<int>>? Function() bodyStream;

    setUp(() {
      completer = Completer<StreamedResponse>();
      steps = [];
      told = [];
      bodyStream = () => null;
    });

    void guard(void Function() handle) => guardResponseCallback(
      completer: completer,
      url: url,
      bodyStream: bodyStream,
      handle: handle,
      closeResponse: () => steps.add('close the response'),
      callOver: () => steps.add('end the call'),
      onError: told.add,
    );

    test('a response that comes after an abort is closed and ends the call, without running the callback', () async {
      final aborted = RequestAbortedException(url);
      final outcome = expectLater(completer.future, throwsA(same(aborted)));
      completer.completeError(aborted);
      // What the callback of upstream did here, which went back to Java
      expect(() => completer.complete(StreamedResponse(const Stream.empty(), 200)), throwsStateError);

      var ran = false;
      expect(() => guard(() => ran = true), returnsNormally);

      expect(ran, isFalse);
      expect(steps, ['close the response', 'end the call']);
      expect(told, isEmpty);
      await outcome;
    });

    test('an error of the callback completes the request with a ClientException, and nothing is thrown', () async {
      // The body stream the callback made before its error, which the caller never gets
      final controller = StreamController<List<int>>();
      bodyStream = () => controller;
      final outcome = expectLater(
        completer.future,
        throwsA(
          isA<ClientException>()
              .having((error) => error.uri, 'uri', url)
              .having((error) => error.message, 'message', contains('no headers')),
        ),
      );

      expect(() => guard(() => throw StateError('no headers')), returnsNormally);

      expect(steps, ['close the response', 'end the call']);
      expect(told, hasLength(1));
      await outcome;
      // Closed, so that the reader of the body adds nothing more to it
      expect(controller.isClosed, isTrue);
      expect(await controller.stream.toList(), isEmpty);
      await controller.close();
    });

    test('a ClientException of the callback, a refused Content-Length, reaches the caller as it is', () async {
      final refused = ClientException('Invalid content-length header', url);
      final outcome = expectLater(completer.future, throwsA(same(refused)));

      guard(() => throw refused);

      expect(steps, ['close the response', 'end the call']);
      expect(told, [same(refused)]);
      await outcome;
    });

    test('an error after the request was answered goes into the body stream, which is closed', () async {
      final controller = StreamController<List<int>>();
      bodyStream = () => controller;
      final events = expectLater(controller.stream, emitsInOrder([emitsError(isA<ClientException>()), emitsDone]));
      final response = StreamedResponse(controller.stream, 200);

      expect(
        () => guard(() {
          completer.complete(response);
          throw StateError('profile closed');
        }),
        returnsNormally,
      );

      expect(await completer.future, same(response));
      expect(controller.isClosed, isTrue);
      expect(steps, ['close the response', 'end the call']);
      expect(told, hasLength(1));
      await events;
      await controller.close();
    });

    test('a callback that answers leaves the response and the call to the reader of the body', () async {
      final response = StreamedResponse(const Stream.empty(), 204);

      guard(() => completer.complete(response));

      expect(steps, isEmpty);
      expect(told, isEmpty);
      expect(await completer.future, same(response));
    });

    test('errors of the cleanup are not thrown, and the call ends even when closing the response fails', () async {
      final outcome = expectLater(completer.future, throwsA(isA<ClientException>()));
      final ended = <String>[];

      expect(
        () => guardResponseCallback(
          completer: completer,
          url: url,
          bodyStream: () => null,
          handle: () => throw StateError('callback'),
          closeResponse: () => throw StateError('response released'),
          callOver: () {
            ended.add('end the call');
            throw StateError('call released');
          },
          onError: (_) => throw StateError('profile closed'),
        ),
        returnsNormally,
      );

      expect(ended, ['end the call']);
      await outcome;
    });
  });

  test('the response callback of OkHttpClient.send goes through the guard', () {
    final client = File('packages/ok_http/lib/src/ok_http_client.dart').readAsStringSync();
    final start = client.indexOf('onResponse: (');
    final end = client.indexOf('onFailure: (', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final onResponse = client.substring(start, end);
    expect(onResponse, contains('guardResponseCallback('));
    expect(onResponse, contains('handle: handle,'));
    expect(onResponse, contains('closeResponse: response.close,'));
    expect(onResponse, contains('callOver: requestObjects.callOver,'));
    // The callback completes the request once, on success; its errors go through the guard only
    expect(RegExp(r'responseCompleter\.complete\(').allMatches(onResponse), hasLength(1));
    expect(onResponse, isNot(contains('responseCompleter.completeError(')));
  });
}
