// No camera account and no RTSP address in any log record of the live view on a computer (plan 2.5, design 5.5): a
// whole session with fake players (opens, a loss, the reopens, a refusal, a stop) next to mpv's lines and errors that
// quote the address with the account, encoded or decoded, or the account on its own, as FFmpeg's RTSP client may.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/camera_live_view.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:logging/logging.dart';

import 'fake_playback_engine.dart';

const _url = 'rtsp://192.0.2.31:554/stream1';
const _user = 'cam-viewer-7';
const _password = 'Tz9 #liveSecret@/:+%';

void main() {
  late List<LogRecord> records;
  late Level previous;

  setUp(() {
    records = [];
    previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previous;
    });
  });

  test('a whole live session and mpv quoting the address leave no account and no address in a record', () {
    fakeAsync((async) {
      final players = FakePlayers();
      final events = <CameraLiveEvent>[];
      final session = CameraLiveSession(
        pool: players.pool,
        onEvent: events.add,
        retryDelays: const [Duration(seconds: 1)],
      );
      unawaited(session.play(url: _url, user: _user, password: _password));
      async.flushMicrotasks();
      final engine = players.made.single;
      final address = engine.resource!;
      expect(address, startsWith('rtsp://cam-viewer-7:Tz9%20%23liveSecret%40%2F%3A%2B%25@'));
      const decoded = 'rtsp://$_user:$_password@192.0.2.31:554/stream1';

      // What FFmpeg and mpv may print at the warning and error levels, the account in every form
      final lines = [
        ('error', 'ffmpeg/demuxer', 'rtsp: method DESCRIBE failed: 401 Unauthorized'),
        ('error', 'cplayer', 'Failed to open $address.'),
        ('error', 'stream', '$decoded: Connection refused'),
        ('warn', 'ffmpeg', 'tcp: Connection to tcp://192.0.2.31:554?timeout=8000000 failed: Connection timed out'),
        ('error', 'ffmpeg/demuxer', 'rtsp: auth $_user:$_password rejected'),
        ('fatal', 'demux', 'user $_user, password ${Uri.encodeComponent(_password)}'),
        ('warn', 'cplayer', 'Set property: stream-open-filename=$address -> 1'),
      ];
      for (final (level, prefix, text) in lines) {
        logPlayerLine(level, prefix, text);
      }

      // A frame, a loss, a reopen that fails with an error quoting the address, the last delay, a give up
      engine.load(Duration.zero, size: (width: 1280, height: 720));
      engine.completed.value = true;
      async.elapse(const Duration(seconds: 1));
      engine.emit(PlayerEventKind.failed, 'loading failed for $decoded');
      async.flushMicrotasks();
      engine.emit(PlayerEventKind.failed, redactPlayerText('loading failed for $address'));
      async.elapse(const Duration(seconds: 5));

      // A second session, refused at once
      unawaited(session.play(url: _url, user: _user, password: _password));
      async.flushMicrotasks();
      engine.emit(
        PlayerEventKind.failed,
        'libmpv: loading failed: method DESCRIBE failed: 401 Unauthorized ($address)',
      );
      async.flushMicrotasks();
      unawaited(session.dispose());
      async.flushMicrotasks();
      async.flushTimers();

      expect(records.where((record) => record.loggerName == 'DesktopPlayer'), hasLength(lines.length));
      expect(records.where((record) => record.loggerName == 'DesktopCameraLive'), isNotEmpty);
      final text = records
          .map((record) => '${record.loggerName} ${record.message} ${record.error ?? ''} ${record.stackTrace ?? ''}')
          .join('\n');
      for (final secret in [
        _password,
        Uri.encodeComponent(_password),
        'Tz9%20%23liveSecret',
        'liveSecret',
        _user,
        address,
        decoded,
        'rtsp://',
      ]) {
        expect(text, isNot(contains(secret)), reason: 'a log record shows $secret');
      }
      // and the reasons shown on the camera page neither
      for (final event in events) {
        expect('${event.error}', isNot(contains('liveSecret')));
        expect('${event.error}', isNot(contains(_user)));
      }
      expect(events.last.error, contains('401'));
    });
  });
}
