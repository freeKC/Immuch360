// The telemetry of ONNX Runtime stays off (review of lot A3b, major 1). The official 1.31.0 for Linux and macOS
// carries Microsoft's 1DS telemetry, on by default: at its first OrtEnv it writes a device id and a queue of events in
// the home folder ($XDG_CACHE_HOME or ~/.cache, then Microsoft/DeveloperTools/.onnxruntime, on Linux; ~/Library/
// Application Support/Microsoft/DeveloperTools/.onnxruntime on macOS), to send them to
// mobile.events.data.microsoft.com. Here a session of the app opens in a process like a user's (a home of its own,
// none of the variables of a CI, which ONNX Runtime takes as "no telemetry" by itself), and nothing may be written
// there. With 1.23.2, which has no telemetry, the test passes anyway. The Windows DLL reports through ETW, which
// leaves no file: there, ort_session_test.dart checks that each session turns its events off (DisableTelemetryEvents).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';
import 'process_environment.dart';

/// The variables by which ONNX Runtime 1.31.0 recognises a CI or its own tests and then keeps its telemetry off by
/// itself (core/platform/telemetry_environment.h): GitHub Actions sets CI and GITHUB_ACTIONS
const _quietVariables = [
  'CI',
  'TF_BUILD',
  'GITHUB_ACTIONS',
  'GITLAB_CI',
  'CIRCLECI',
  'TRAVIS',
  'JENKINS_URL',
  'CODEBUILD_BUILD_ID',
  'BUILDKITE',
  'TEAMCITY_VERSION',
  'APPVEYOR',
  'BITBUCKET_BUILD_NUMBER',
  'SYSTEM_TEAMFOUNDATIONCOLLECTIONURI',
  'ORT_RUNNING_UNIT_TESTS',
];

void main() {
  final ort = ortForTests();

  test('a session of the app writes no device id and no queue of events for the telemetry of ONNX Runtime', () {
    final home = Directory.systemTemp.createTempSync('ort-telemetry-home');
    final changed = ['HOME', 'XDG_CACHE_HOME', ortTelemetryOffVariable, ..._quietVariables];
    final saved = {for (final name in changed) name: processVariable(name)};
    addTearDown(() {
      for (final MapEntry(:key, :value) in saved.entries) {
        setProcessVariable(key, value);
      }
      home.deleteSync(recursive: true);
    });
    setProcessVariable('HOME', home.path);
    for (final name in changed.skip(1)) {
      setProcessVariable(name, null);
    }

    final runtime = OrtRuntime.load(ort.library!);
    runtime.openSession(tinyDepthModelPath(), settings: const OrtSessionSettings(intraOpThreads: 1)).close();

    expect(home.listSync(recursive: true).map((entry) => p.relative(entry.path, from: home.path)), isEmpty);
    expect(processVariable(ortTelemetryOffVariable), '1');
    if (runtime.version == '1.31.0') {
      // Not a pass by a silent library: this one carries the collector of 1DS
      expect(latin1.decode(File(ort.library!).readAsBytesSync()), contains('mobile.events.data.microsoft.com'));
    }
  }, skip: ort.skip ?? (Platform.isWindows ? 'Windows: the DLL reports through ETW, which leaves no file' : null));
}
