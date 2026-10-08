import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/decode_queue.dart';

/// A job whose end the test decides, recording when it starts
class _Gate {
  _Gate(this.name, this.started);

  final String name;
  final List<String> started;
  final done = Completer<Uint8List>();

  Future<Uint8List> work() {
    started.add(name);
    return done.future;
  }

  void finish() => done.complete(Uint8List.fromList(name.codeUnits));
}

void main() {
  test('runs a few at a time, the latest requested first', () async {
    final started = <String>[];
    final queue = DecodeQueue(2);
    final gates = {
      for (final name in ['a', 'b', 'c', 'd', 'e']) name: _Gate(name, started),
    };
    final results = <String, Future<Uint8List?>>{};
    var id = 0;
    for (final gate in gates.values) {
      results[gate.name] = queue.run(gate.name, id++, gate.work);
    }

    await pumpEventQueue();
    expect(started, ['a', 'b'], reason: 'two slots');

    gates['a']!.finish();
    await pumpEventQueue();
    expect(started, ['a', 'b', 'e'], reason: 'the last one asked for, the tile now on screen');

    gates['b']!.finish();
    gates['e']!.finish();
    await pumpEventQueue();
    expect(started, ['a', 'b', 'e', 'd', 'c']);
    gates['d']!.finish();
    gates['c']!.finish();
    expect(String.fromCharCodes((await results['c']!)!), 'c');
  });

  test('one job for every request of the same key, which all get its result', () async {
    final started = <String>[];
    final queue = DecodeQueue(1);
    final gate = _Gate('x', started);
    final first = queue.run('x', 1, gate.work);
    final second = queue.run('x', 2, gate.work);
    await pumpEventQueue();
    gate.finish();
    expect(await first, await second);
    expect(started, ['x']);
  });

  test('a job whose requests were all cancelled before it started is dropped', () async {
    final started = <String>[];
    final queue = DecodeQueue(1);
    final busy = _Gate('busy', started);
    final waiting = _Gate('waiting', started);
    final shared = _Gate('shared', started);
    unawaited(queue.run('busy', 1, busy.work));
    final dropped = queue.run('waiting', 2, waiting.work);
    final kept = queue.run('shared', 3, shared.work);
    final keptToo = queue.run('shared', 4, shared.work);

    queue.cancel(2);
    queue.cancel(3);
    expect(await dropped, isNull);

    busy.finish();
    await pumpEventQueue();
    expect(started, ['busy', 'shared'], reason: 'request 4 still wants the shared one');
    shared.finish();
    expect(await kept, isNotNull);
    expect(await keptToo, isNotNull);
  });

  test('cancelling a running job lets it finish, its result is kept for the others', () async {
    final started = <String>[];
    final queue = DecodeQueue(1);
    final gate = _Gate('running', started);
    final result = queue.run('running', 1, gate.work);
    await pumpEventQueue();
    queue.cancel(1);
    gate.finish();
    expect(await result, isNotNull);
  });

  test('a failed job fails its requests and frees its slot', () async {
    final queue = DecodeQueue(1);
    final failing = queue.run('bad', 1, () async => throw const FormatException('broken'));
    final next = queue.run('good', 2, () async => Uint8List(1));
    await expectLater(failing, throwsFormatException);
    expect(await next, isNotNull);
  });
}
