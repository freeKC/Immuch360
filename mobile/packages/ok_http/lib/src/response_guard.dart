// Immuch360: a file of the copy, not of upstream ok_http (IMMUCH360-NOTE.md).
// It has no JNI in it, so that a test of the app runs it on any platform.

import 'dart:async';

import 'package:http/http.dart';

/// Runs [handle], the Dart side of OkHttp's `Callback.onResponse`, so that no
/// error goes back to Java.
///
/// The callback is a synchronous proxy of package:jni: OkHttp's dispatcher
/// thread waits for Dart, and an error of Dart is thrown again on that thread,
/// where `RealCall.AsyncCall.run` rethrows any `Throwable` and the app ends.
///
/// The response may come after [completer] was completed, by an abort or by
/// the streaming of the request body that failed: [handle] does not run then,
/// since completing [completer] again would throw. When [handle] throws, the
/// error goes to the caller instead, as a [ClientException]: as the result of
/// [completer] while it is not completed, or else into the body stream that
/// [bodyStream] returns; that stream, if any, is closed, and [onError] is
/// told. In both cases [closeResponse] frees the connection, then [callOver]
/// ends the call (the JNI objects of the request). On success [handle]
/// completes [completer] itself and the body is read to its end. Errors of
/// [onError], [closeResponse] and [callOver] are dropped: nothing is left to
/// tell.
void guardResponseCallback({
  required Completer<StreamedResponse> completer,
  required Uri url,
  required StreamController<List<int>>? Function() bodyStream,
  required void Function() handle,
  required void Function() closeResponse,
  required void Function() callOver,
  void Function(ClientException error)? onError,
}) {
  if (!completer.isCompleted) {
    try {
      handle();
      return;
    } catch (error, stackTrace) {
      final exception =
          error is ClientException ? error : ClientException('$error', url);
      _quietly(() {
        final stream = bodyStream();
        if (!completer.isCompleted) {
          completer.completeError(exception, stackTrace);
        } else if (stream != null && !stream.isClosed) {
          stream.addError(exception, stackTrace);
        }
        // The reader of the body may still add to it: it takes nothing more
        if (stream != null && !stream.isClosed) {
          unawaited(stream.close());
        }
      });
      if (onError != null) {
        _quietly(() => onError(exception));
      }
    }
  }
  _quietly(closeResponse);
  _quietly(callOver);
}

void _quietly(void Function() action) {
  try {
    action();
  } catch (_) {
    // Nothing may go back to Java from the callback
  }
}
