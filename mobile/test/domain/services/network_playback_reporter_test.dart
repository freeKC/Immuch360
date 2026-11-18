// The playback reports of the video page to a media server (a Jellyfin or Emby server): start once it plays,
// progress every minute while it plays and at a pause, stopped once as the page goes; a server that fails is told
// nothing more of it and playback goes on; a share without reports gets none.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_playback_reporter.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';

class _Player extends VideoPlayerNotifier {
  void emit({Duration? position, VideoPlaybackStatus? status}) {
    state = state.copyWith(position: position ?? state.position, status: status ?? state.status);
  }
}

class _Reports implements NetworkPlaybackReports {
  final sent = <String>[];
  bool fails = false;

  Future<void> _add(String line) async {
    sent.add(line);
    if (fails) {
      throw StateError('server down');
    }
  }

  @override
  Future<void> playbackStarted(String path, Duration position, {bool converted = false}) =>
      _add('start $path ${position.inSeconds}${converted ? ' converted' : ''}');

  @override
  Future<void> playbackProgress(String path, Duration position, {bool paused = false}) =>
      _add('progress ${position.inSeconds}${paused ? ' paused' : ''}');

  @override
  Future<void> playbackStopped(String path, Duration position) => _add('stopped ${position.inSeconds}');
}

void main() {
  test('start, progress every minute and at a pause, stopped once', () {
    fakeAsync((async) {
      final player = _Player();
      final reports = _Reports();
      final reporter = NetworkPlaybackReporter(reports: reports, player: player, path: '/Films/a.mkv')..start();
      player.emit(status: VideoPlaybackStatus.buffering);
      async.flushMicrotasks();
      expect(reports.sent, isEmpty, reason: 'nothing before it plays');
      player.emit(status: VideoPlaybackStatus.playing, position: const Duration(seconds: 62));
      async.flushMicrotasks();
      expect(reports.sent, ['start /Films/a.mkv 62']);
      player.emit(position: const Duration(seconds: 100));
      async.elapse(const Duration(seconds: 61));
      expect(reports.sent.last, 'progress 100');
      player.emit(status: VideoPlaybackStatus.paused, position: const Duration(seconds: 130));
      async.flushMicrotasks();
      expect(reports.sent.last, 'progress 130 paused');
      async.elapse(const Duration(minutes: 3));
      expect(reports.sent, hasLength(3), reason: 'no progress while paused');
      reporter.dispose();
      reporter.dispose();
      async.flushMicrotasks();
      expect(reports.sent, ['start /Films/a.mkv 62', 'progress 100', 'progress 130 paused', 'stopped 130']);
      player.dispose();
    });
  });

  test('a conversion says so; a film that never played reports nothing', () {
    fakeAsync((async) {
      final player = _Player();
      final reports = _Reports();
      NetworkPlaybackReporter(reports: reports, player: player, path: '/b.mkv').start();
      player.emit(status: VideoPlaybackStatus.buffering);
      async.flushMicrotasks();
      final unplayed = NetworkPlaybackReporter(reports: reports, player: player, path: '/b.mkv');
      unplayed.dispose();
      expect(reports.sent, isEmpty);
      final converted = NetworkPlaybackReporter(reports: reports, player: player, path: '/c.mkv', converted: true)
        ..start();
      player.emit(status: VideoPlaybackStatus.paused);
      player.emit(status: VideoPlaybackStatus.playing, position: Duration.zero);
      async.flushMicrotasks();
      expect(reports.sent.last, 'start /c.mkv 0 converted');
      converted.dispose();
      player.dispose();
    });
  });

  test('a server that fails does not stop the player, and is reported once in the log', () {
    fakeAsync((async) {
      final player = _Player();
      final reports = _Reports()..fails = true;
      final reporter = NetworkPlaybackReporter(reports: reports, player: player, path: '/a.mkv')..start();
      player.emit(status: VideoPlaybackStatus.buffering);
      player.emit(status: VideoPlaybackStatus.playing, position: const Duration(seconds: 5));
      async.elapse(const Duration(minutes: 2));
      reporter.dispose();
      async.flushMicrotasks();
      expect(reports.sent, hasLength(4));
      expect(player.state.status, VideoPlaybackStatus.playing);
      player.dispose();
    });
  });
}
