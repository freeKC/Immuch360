// When immuch360-libmpv.yml publishes a release of libmpv (review of lot AD4, n4, taken by lot AD11 of the AV2
// videos): only a run by hand that asks for it. A push to the desktop branch that touches the recipe (the merge of
// feat-av2 brings .github/desktop/libmpv-macos/) builds and checks both libmpv, but publishes nothing: the releases the
// app pins (Package.swift, the CMakeLists of the Windows libs) are made by hand, and a push had already left
// libmpv-macos-20261020-10 beside the pinned -9.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

final File _workflow = File(p.join(repositoryRoot, '.github', 'workflows', 'immuch360-libmpv.yml'));

/// The condition of the job [job]: its "if:", folded lines joined
String _condition(String workflow, String job) {
  final lines = workflow.split('\n');
  final start = lines.indexOf('  $job:');
  expect(start, isNot(-1), reason: 'no job $job');
  final parts = <String>[];
  for (var i = start + 1; i < lines.length && !RegExp(r'^  \S').hasMatch(lines[i]); i++) {
    final line = lines[i];
    if (line.startsWith('    if:')) {
      parts.add(line.substring('    if:'.length).replaceFirst('>-', '').trim());
      for (var j = i + 1; j < lines.length && lines[j].startsWith('      ') && !lines[j].trim().endsWith(':'); j++) {
        parts.add(lines[j].trim());
      }
      break;
    }
  }
  return parts.join(' ').trim();
}

void main() {
  final workflow = _workflow.existsSync() ? _workflow.readAsStringSync().replaceAll('\r\n', '\n') : '';

  test('a push to the desktop branch still builds both libmpv', () {
    expect(workflow, contains('  push:\n    branches: [desktop]'));
  }, skip: workflow.isEmpty ? 'no immuch360-libmpv.yml' : false);

  for (final job in ['publish', 'macos-publish']) {
    test('$job publishes for a run by hand that asks for it, never on a push or the schedule', () {
      final condition = _condition(workflow, job);
      expect(condition, contains("github.event_name == 'workflow_dispatch' && inputs.publish"));
      expect(condition, isNot(contains("github.event_name != 'workflow_dispatch' || inputs.publish")));
    }, skip: workflow.isEmpty ? 'no immuch360-libmpv.yml' : false);
  }
}
