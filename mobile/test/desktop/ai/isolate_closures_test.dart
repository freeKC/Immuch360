// The rule issue 23 taught, checked on the sources of the AI features: a closure handed to Isolate.run (or to a
// PanoramaCompute) is built in a top-level function, never in a method of a class. A Dart closure keeps the whole
// context of the scope it is built in, not only what it reads: built inside the run of an engine, it carries the
// progress callback of the queue of the app, which holds the queue, its tools and their DesktopAiSettingsStore, and no
// isolate takes the futures they hold ("Illegal argument in isolate message: object is unsendable"). Every photo of
// Enhance (AI) failed so in desktop builds 31 and 32, and every 360° panorama before lot V3; the tests with fakes gave
// callbacks over plain lists and never saw it. The isolates of each kind are also run for real with a callback like
// the app's (fakes/app_progress.dart) in the tests of their engines and in enhance/enhance_isolates_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// [source] with its comments and the text of its strings blanked (their length kept), so that braces count
String codeOnly(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;

  // Blanks a string starting at i (after any r prefix), returns the index after it
  int skipString(int start, {required bool raw}) {
    final quote = source[start];
    final triple = start + 2 < n && source[start + 1] == quote && source[start + 2] == quote;
    final close = triple ? quote * 3 : quote;
    var j = start + close.length;
    while (j < n) {
      if (!raw && source[j] == r'\') {
        j += 2;
        continue;
      }
      if (!raw && source[j] == r'$' && j + 1 < n && source[j + 1] == '{') {
        // An interpolation: skipped to its closing brace, the strings inside it too
        var depth = 1;
        j += 2;
        while (j < n && depth > 0) {
          final c = source[j];
          if (c == "'" || c == '"') {
            j = skipString(j, raw: false);
            continue;
          }
          if (c == '{') {
            depth++;
          } else if (c == '}') {
            depth--;
          }
          j++;
        }
        continue;
      }
      if (source.startsWith(close, j)) {
        return j + close.length;
      }
      if (!triple && source[j] == '\n') {
        return j;
      }
      j++;
    }
    return n;
  }

  while (i < n) {
    final c = source[i];
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      final to = end < 0 ? n : end;
      out.write(' ' * (to - i));
      i = to;
    } else if (source.startsWith('/*', i)) {
      var depth = 0;
      var j = i;
      do {
        if (source.startsWith('/*', j)) {
          depth++;
          j += 2;
        } else if (source.startsWith('*/', j)) {
          depth--;
          j += 2;
        } else {
          j++;
        }
      } while (depth > 0 && j < n);
      out.write(source.substring(i, j).replaceAll(RegExp(r'[^\n]'), ' '));
      i = j;
    } else if (c == "'" || c == '"' || (c == 'r' && i + 1 < n && (source[i + 1] == "'" || source[i + 1] == '"'))) {
      final raw = c == 'r';
      if (raw && i > 0 && RegExp(r'[A-Za-z0-9_$]').hasMatch(source[i - 1])) {
        out.write(c);
        i++;
        continue;
      }
      final end = skipString(raw ? i + 1 : i, raw: raw);
      out.write(source.substring(i, end).replaceAll(RegExp(r'[^\n]'), ' '));
      i = end;
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The calls of [code] that hand a closure to another isolate and stand inside the body of a class, a mixin, an
/// extension or an enum, as "line: declaration"
List<String> isolateCallsInClasses(String code) {
  final calls = RegExp(r'Isolate\.run\s*[<(]|(?<![\w.$])compute\s*\(');
  final found = <String>[];
  for (final call in calls.allMatches(code)) {
    // The top-level declaration the call stands in: from the end of the one before at depth 0
    var depth = 0;
    var start = 0;
    for (var i = 0; i < call.start; i++) {
      final c = code[i];
      if (c == '{' || c == '(' || c == '[') {
        depth++;
      } else if (c == '}' || c == ')' || c == ']') {
        depth--;
        if (depth == 0 && c == '}') {
          start = i + 1;
        }
      } else if (c == ';' && depth == 0) {
        start = i + 1;
      }
    }
    if (depth == 0) {
      continue;
    }
    final header = code.substring(start, call.start).trimLeft().replaceFirst(RegExp(r'^(@[\w.]+(\([^)]*\))?\s*)*'), '');
    final kind = RegExp(
      r'^((abstract|base|final|sealed|interface|mixin)\s+)*(class|mixin|extension|enum)\s+([\w$]*)',
    ).firstMatch(header);
    if (kind != null) {
      final line = '\n'.allMatches(code.substring(0, call.start)).length + 1;
      found.add('$line: ${kind.group(3)} ${kind.group(4)}');
    }
  }
  return found;
}

void main() {
  test('the scanner sees a call in a method and lets a top-level one be', () {
    const source = '''
// Isolate.run(() => 1) in a comment
class Engine {
  Future<int> run(void Function() onProgress) async {
    final text = "Isolate.run(\${'{'}";
    return Isolate.run(() => 2);
  }
}

Future<int> plain(int value) => Isolate.run(() => value);

extension on int {
  Future<void> twice() => compute(() {});
}

final provider = Provider((ref) => Isolate.run(() => 3));
''';
    expect(isolateCallsInClasses(codeOnly(source)), ['5: class Engine', '12: extension on']);
  });

  test('no closure is sent to an isolate from inside a class in the AI features', () {
    final folder = Directory(p.join('lib', 'desktop', 'ai'));
    final offending = <String>[];
    for (final file in folder.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) {
        continue;
      }
      for (final call in isolateCallsInClasses(codeOnly(file.readAsStringSync()))) {
        offending.add('${file.path}:$call');
      }
    }
    expect(
      offending,
      isEmpty,
      reason:
          'Build the closure in a top-level function that takes plain data (decodeEnhanceJpegInIsolate, '
          'checkGeneratedFileInIsolate): a closure built in a method carries the context of that method',
    );
  });
}
