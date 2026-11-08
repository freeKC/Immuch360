import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards of the copy of ok_http in packages/ok_http (crash family F2 of release 44, SIGSEGV in libdartjni under
/// globalEnv_CallObjectMethod). The bindings of jnigen 0.15 passed the receiver of each JNI call as
/// `reference.pointer` read on a `JObject`, which nothing kept alive during the call; the copy binds it to a local
/// first, as jnigen 0.17 does (packages/ok_http/IMMUCH360-NOTE.md). A copy taken again from upstream, or a return to
/// the git dependency, would bring the old bindings back: these tests fail then.
void main() {
  // A receiver use: `reference.pointer` not preceded by a word character, `.` or `$`, so neither
  // `_class.reference.pointer` (static members) nor `_$string.pointer` (arguments) counts
  final receiverUse = RegExp(r'(?<![\w.$])reference\.pointer');
  const selfRef = r'final _$$selfRef = reference;';

  test('every instance call of the ok_http bindings keeps its receiver in a local', () {
    final bindings = File('packages/ok_http/lib/src/jni/bindings.dart').readAsStringSync();
    final left = receiverUse.allMatches(bindings).map((match) => bindings.substring(0, match.start).split('\n').length);
    expect(left, isEmpty, reason: 'lines of bindings.dart that pass reference.pointer as the receiver');
    final bound = selfRef.allMatches(bindings).length;
    expect(bound, greaterThanOrEqualTo(540));
    expect(r'_$$selfRef.pointer'.allMatches(bindings).length, bound);
    // The static members keep the class reference, which a static field holds for good
    expect('_class.reference.pointer'.allMatches(bindings), isNotEmpty);
  });

  test('send() and the opening of a web socket call nothing on the chained temporaries of the crash traces', () {
    final client = File('packages/ok_http/lib/src/ok_http_client.dart').readAsStringSync();
    final webSocket = File('packages/ok_http/lib/src/ok_http_web_socket.dart').readAsStringSync();
    for (final source in [client, webSocket]) {
      // Play P1: Request$Builder.url$1 called on a builder that nothing else holds
      expect(source, isNot(matches(RegExp(r'Request\$Builder\(\)\s*\.url\$1\('))));
      // Play P2: OkHttpClient$Builder.followRedirects called on the builder newBuilder() returns
      expect(source, isNot(matches(RegExp(r'newBuilder\(\)\s*\.followRedirects\('))));
      // Play P3: OkHttpClient$Builder.build called at the end of the chain of timeouts
      expect(source, isNot(matches(RegExp(r'writeTimeout\([^;]*?\)\s*\.build\(\)'))));
    }
    // The objects that callbacks still use after send() returns go once the request is over
    expect(client, contains('class _RequestObjects'));
  });

  test('the app resolves ok_http from the copy in packages/ok_http', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, matches(RegExp(r'\n  ok_http:\r?\n    path: packages/ok_http\r?\n')));
    final lock = File('pubspec.lock').readAsStringSync();
    final entry = RegExp(r'\n  ok_http:\r?\n((?:    .*\r?\n)+)').firstMatch(lock);
    expect(entry, isNotNull);
    final lines = entry!.group(1)!.split('\n').map((line) => line.trim()).toList();
    expect(lines, containsAll(['path: "packages/ok_http"', 'relative: true', 'source: path']));
  });
}
