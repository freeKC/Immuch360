// The media port client against the fake Streamd on 127.0.0.1: the Digest login on a second connection, the parts
// decrypted with the key exchange, the acknowledgements at 25 and 50, finished, do stop; the picture of a recording on
// a connection of its own; the busy answers; a refused password told as the videos being locked.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_session.dart';

import 'fake_streamd.dart';
import 'tapo_test_streams.dart';

const _password = 'synthetic-cloud-password';
const _player = '0123456789ABCDEF0123456789ABCDEF';

void main() {
  late FakeStreamd streamd;

  setUp(() async => streamd = await FakeStreamd.start());
  tearDown(() => streamd.close());

  test('logs in, decrypts a clip, acknowledges every 25th part and stops', () async {
    final frames = fixtureAccessUnits();
    streamd.clip = clipParts([...frames, ...frames]);
    final session = await TapoMediaSession.open('127.0.0.1', _password, port: streamd.port);
    final received = BytesBuilder();
    final finished = await tapoDownloadClip(
      session,
      start: 1000,
      end: 1002,
      playerId: _player,
      onData: (part) => received.add(part.body),
    );
    session.stop();
    await session.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(finished, isTrue);
    expect(streamd.errors, isEmpty);
    expect(streamd.connections, 2);
    final expected = BytesBuilder();
    for (final part in streamd.clip) {
      expected.add(part.ts);
    }
    expect(received.takeBytes(), expected.takeBytes());
    final request = streamd.requests.single;
    final download = (request['params']! as Map)['download'] as Map;
    expect(download['media_type'], 0);
    expect((download['start_time'], download['end_time']), ('1000', '1002'));
    expect(download['player_id'], _player);
    expect(streamd.requestHeaders.single['x-data-window-size'], '50');
    expect(streamd.acks.map((ack) => ack['x-data-received']), containsAllInOrder(['25', '50']));
    expect(streamd.acks.first['x-session-id'], '21');
    expect(streamd.stops.single['x-session-id'], '21');
  });

  test('fetches the picture of a recording without an end time', () async {
    final session = await TapoMediaSession.open('127.0.0.1', _password, port: streamd.port);
    final image = await tapoSnapshot(session, start: 1234, playerId: _player);
    await session.close();
    expect(image, fakeSnapshot);
    final download = (streamd.requests.single['params']! as Map)['download'] as Map;
    expect(download['media_type'], 2);
    expect(download['start_time'], '1234');
    expect(download.containsKey('end_time'), isFalse);
  });

  test('tells a busy camera apart', () async {
    streamd.refuseNext.add(-52405);
    final session = await TapoMediaSession.open('127.0.0.1', _password, port: streamd.port);
    await expectLater(
      tapoDownloadClip(session, start: 1000, end: 1002, playerId: _player, onData: (_) {}),
      throwsA(
        isA<TapoCameraException>()
            .having((e) => e.kind, 'kind', TapoErrorKind.busy)
            .having((e) => e.code, 'code', -52405),
      ),
    );
    await session.close();
  });

  test('tells a refused password as videos locked to this password', () async {
    streamd.refusePassword = true;
    await expectLater(
      TapoMediaSession.open('127.0.0.1', _password, port: streamd.port),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.mediaLocked)),
    );
  });

  test('tells parts that do not decrypt as videos locked to another password', () async {
    streamd.scrambleParts = true;
    final session = await TapoMediaSession.open('127.0.0.1', _password, port: streamd.port);
    await expectLater(
      tapoDownloadClip(session, start: 1000, end: 1002, playerId: _player, onData: (_) {}),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.mediaLocked)),
    );
    await session.close();
  });

  test('tells an unreachable media port', () async {
    final port = streamd.port;
    await streamd.close();
    await expectLater(
      TapoMediaSession.open('127.0.0.1', _password, port: port, timeout: const Duration(seconds: 2)),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.unreachable)),
    );
  });

  test('builds the download request of the official app', () {
    expect(tapoDownloadParams(start: 1, end: 2, playerId: _player), {
      'download': {
        'client_id': 1,
        'channels': [0],
        'media_type': 0,
        'start_time': '1',
        'end_time': '2',
        'player_id': _player,
      },
      'method': 'get',
    });
    expect(
      tapoControlPart(
        Uint8List.fromList(
          '{"type":"notification", "params":{"event_type":"stream_status", "status":"finished"}}'.codeUnits,
        ),
      ).finished,
      isTrue,
    );
    expect(clipParts(fixtureAccessUnits()), isNotEmpty);
  });
}
