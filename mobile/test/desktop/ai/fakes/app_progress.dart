// What the queue of the app hands an engine as its progress callback, for the tests of the isolates an engine starts.
// ConversionQueueNotifier._run gives `(progress) => _progress(id, progress, timings, tools.now)`: a closure over the
// notifier and its ConversionTools, whose DesktopAiSettingsStore holds a Future. A closure an engine sends to an
// isolate from a scope that also captures that callback carries it along, and no isolate takes a Future: "Illegal
// argument in isolate message: object is unsendable - Library:'dart:async' Class: _Future" (issue 23, every photo of
// Enhance (AI) in desktop builds 31 and 32). The fakes of the tests used to give callbacks over plain lists, which any
// isolate takes, so that no test saw it.

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';

/// A real settings store, as the tools of the app hold one
DesktopAiSettingsStore appSettingsStore() =>
    DesktopAiSettingsStore(settingsDirectory: () async => Directory.systemTemp.createTempSync('app-progress-'));

/// A callback that adds what it is given to [heard] and, as the one of the app, holds a settings store: no isolate
/// takes it
void Function(T value) appLikeCallback<T>(List<T> heard) {
  final store = appSettingsStore();
  return (value) {
    if (!identical(store, heard)) {
      heard.add(value);
    }
  };
}

/// [value] cannot be sent to an isolate: the guard of a test is not vacuous
Future<void> expectUnsendable(Object value) async {
  await expectLater(
    Isolate.run(() => value.hashCode),
    throwsA(isA<ArgumentError>().having((error) => '$error', 'message', contains('unsendable'))),
  );
}
