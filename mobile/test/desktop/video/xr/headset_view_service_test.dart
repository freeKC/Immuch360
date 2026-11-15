// The headset view's service (lib/desktop/video/xr/headset_view_service.dart) on a fake plugin: availability, one
// session from one video to the next, the dark room once no page is left, the stops, the close step, the controllers'
// events applied once each, the crash guard, the log files and the app's log.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/desktop/window/close_sequence.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/xr.dart';
import 'package:path/path.dart' as p;

import 'headset_test_support.dart';

void main() {
  late Directory folder;
  late FakeHeadsetApi api;
  late List<HeadsetNotice> notices;
  late HeadsetViewService service;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('headset_view_test');
    api = FakeHeadsetApi();
    notices = [];
    service = testService(api, folder, notices: notices);
  });

  tearDown(() async {
    service.dispose();
    await folder.delete(recursive: true);
  });

  /// The service and its queue settle
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  group('availability', () {
    test('Linux and macOS: not available, nothing asked of the plugin', () async {
      api.windows = false;
      final page = FakePage();
      service.register(page.target);
      await settle();
      expect(service.available, isFalse);
      expect(service.runtime?.reason, XrStopReason.notWindows);
      await service.startUp();
      expect(File(p.join(folder.path, HeadsetViewSettings.fileName)).existsSync(), isFalse, reason: 'nothing read');
    });

    test('a build without the option, no runtime registered, a runtime, the switch off', () async {
      final page = FakePage();
      api.info = XrRuntimeInfo.notInBuild;
      service.register(page.target);
      await settle();
      expect(service.available, isFalse, reason: 'not in this build');

      api.info = const XrRuntimeInfo(compiled: true, registered: false);
      await service.refreshRuntime();
      expect(service.available, isFalse, reason: 'no runtime registered');

      api.info = steamVr;
      await service.refreshRuntime();
      expect(service.available, isTrue);
      expect(service.handlesKeys, isTrue);

      await service.settings.setEnabled(false);
      expect(service.available, isFalse, reason: 'the switch off');
      expect(service.handlesKeys, isFalse);
    });

    test('the switch is on by default, kept in desktop_xr.json with the two other settings', () async {
      final settings = HeadsetViewSettings(folder: () async => folder);
      await settings.load();
      expect(settings.enabled.value, isTrue);
      expect(settings.matchRefreshRate.value, isTrue);
      expect(settings.pauseWhenTakenOff.value, isTrue);
      await settings.setMatchRefreshRate(false);
      await settings.setPauseWhenTakenOff(false);
      await settings.setEnabled(false);
      final again = HeadsetViewSettings(folder: () async => folder);
      await again.load();
      expect(again.enabled.value, isFalse);
      expect(again.matchRefreshRate.value, isFalse);
      expect(again.pauseWhenTakenOff.value, isFalse);
    });

    test("the probe's file of 14 November leaves the feature on", () async {
      File(p.join(folder.path, HeadsetViewSettings.fileName)).writeAsStringSync('{"probe":false}');
      final settings = HeadsetViewSettings(folder: () async => folder);
      await settings.load();
      expect(settings.enabled.value, isTrue);
    });
  });

  group('one session', () {
    test('a page that cannot go to the headset yet: no start, and the dark room while a view runs', () async {
      final page = FakePage()..notAvailable = 'a raw file drawn by two players';
      service.register(page.target);
      await settle();
      await service.toggle();
      await service.start(HeadsetChoice.around);
      expect(api.starts, isEmpty, reason: 'neither H nor the menu starts it');
      expect(service.running, isFalse);

      // A view runs on another page; this one comes on screen
      final other = FakePage(handle: 9);
      service.register(other.target);
      await service.start(HeadsetChoice.around);
      expect(api.starts.single.content.handle, 9);
      service.unregister(other.target);
      service.unregister(page.target);
      service.register(page.target);
      await settle();
      expect(api.contents.last.mode, XrHeadsetMode.idle, reason: 'one lens is never shown');
      expect(service.shown, isNull);

      // Its second player went (one player draws the whole frame): shown on the next change
      page.notAvailable = null;
      await service.start(HeadsetChoice.around);
      await settle();
      expect(api.contents.last.handle, 7);
      expect(service.shown, same(page.target));
      // And the other way round, while it is shown
      page.notAvailable = 'a raw file drawn by two players';
      page.changed.fire();
      await settle();
      expect(api.contents.last.mode, XrHeadsetMode.idle);
      expect(service.running, isTrue, reason: 'the view stays, in its dark room');
    });

    test('start: the page, its layout, yaw and rate, a log file, the names of the actions', () async {
      final page = FakePage(stereo: XrStereo.leftRight)..frameRate.value = 29.97;
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      expect(api.starts, hasLength(1));
      final request = api.starts.single;
      expect(request.content.handle, 7);
      expect(request.content.mode, XrHeadsetMode.sphere);
      expect(request.content.stereo, XrStereo.leftRight);
      expect(request.content.fps, 29.97);
      expect(request.content.yaw, 40);
      expect(request.content.label, '360 player, 360 video, sphere, 3D side by side');
      expect(request.matchRefreshRate, isTrue);
      expect(request.appVersion, '3.4.2+3030046, media_kit_360 $headsetPluginCommit');
      expect(request.actionNames.keys, containsAll(['player', 'play_pause', 'seek', 'recenter', 'exit']));
      expect(p.dirname(request.logPath), p.join(folder.path, 'headset'));
      expect(p.basename(request.logPath), matches(RegExp(r'^headset-\d{8}-\d{6}\.log$')));
      expect(page.calls, ['prepare around', 'subtitles hidden'], reason: 'around: the strip shows the subtitles');
      expect(notices, [const HeadsetNotice(HeadsetNoticeKind.experimental)]);
      expect(service.phase, HeadsetViewPhase.starting);
      api.phase = 'waiting for the headset';
      await service.tick();
      expect(service.phase, HeadsetViewPhase.waiting);
      api.phase = 'running';
      await service.tick();
      expect(service.phase, HeadsetViewPhase.running);
      expect(service.headset, 'Meta Quest 3');
    });

    test('the next video attaches with no new start; back to the library: the dark room', () async {
      final first = FakePage();
      service.register(first.target);
      await service.start(HeadsetChoice.around);
      final next = FakePage(
        choices: const [HeadsetChoice.screen2d, HeadsetChoice.screenSideBySide, HeadsetChoice.screenOverUnder],
        preselected: HeadsetChoice.screenSideBySide,
        handle: 9,
        source: HeadsetSourceKind.plex,
        video: HeadsetVideoKind.flat,
      );
      service.unregister(first.target);
      service.register(next.target);
      await settle();
      expect(api.starts, hasLength(1), reason: 'never a second session');
      final shown = api.contents.last;
      expect(shown.handle, 9);
      expect(shown.mode, XrHeadsetMode.screen);
      expect(shown.stereo, XrStereo.leftRight);
      expect(shown.squeeze, XrEyeSqueeze.full, reason: '3840 x 1080: two full eyes');
      expect(shown.label, 'Plex, flat film, screen, 3D side by side');
      expect(first.calls, contains('release'));
      expect(next.calls, contains('prepare screenSideBySide'));
      expect(service.shown, same(next.target));

      service.unregister(next.target);
      await settle();
      expect(api.contents.last, XrContent.idle);
      expect(next.calls.last, 'release');
      expect(service.shown, isNull);
      expect(service.running, isTrue, reason: 'the headset waits for a video');
    });

    test('a start while one runs changes the content, never a second session', () async {
      final page = FakePage();
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      await service.start(HeadsetChoice.screen2d);
      expect(api.starts, hasLength(1));
      expect(api.contents.last.mode, XrHeadsetMode.screen);
      expect(service.choice, HeadsetChoice.screen2d);
    });

    test('stop: the page released, no notice, the marker cleared; H starts and stops', () async {
      final page = FakePage();
      service.register(page.target);
      await service.refreshRuntime();
      await service.toggle();
      expect(api.starts.single.content.mode, XrHeadsetMode.sphere, reason: 'H starts the marked choice');
      expect(service.settings.runningMarker, isTrue);
      await service.toggle();
      expect(api.stops, 1);
      expect(service.running, isFalse);
      expect(page.calls, containsAllInOrder(['prepare around', 'subtitles hidden', 'subtitles shown', 'release']));
      expect(notices, [const HeadsetNotice(HeadsetNoticeKind.experimental)]);
      expect(page.calls, isNot(contains('pause')), reason: 'asked from the window');
      expect(service.settings.runningMarker, isFalse);
    });

    test('the close step ends the view within its bound, even when the runtime hangs', () async {
      final page = FakePage();
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      api.stopHangs = Completer<void>();
      final watch = Stopwatch()..start();
      final ends = await runDesktopClose([
        DesktopCloseStep('the headset view ends', DesktopCloseBounds.headsetView, service.closeForExit),
      ]);
      expect(ends['the headset view ends'], DesktopCloseStepEnd.timedOut);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(service.settings.runningMarker, isFalse, reason: 'a close on purpose is no crash');
      api.stopHangs!.complete();
      await settle();
      expect(service.running, isFalse);
    });

    test('the close sequence has the step only while a view runs, before the players', () async {
      final container = ProviderContainer(overrides: [headsetViewServiceProvider.overrideWithValue(service)]);
      addTearDown(container.dispose);
      container.read(headsetViewServiceProvider);
      List<String> names() => container.read(desktopCloseStepsProvider)().map((step) => step.name).toList();
      expect(names(), isNot(contains('the headset view ends')));
      final page = FakePage();
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      final steps = names();
      expect(steps.indexOf('the headset view ends'), lessThan(steps.indexOf('the players')));
      expect(DesktopCloseBounds.total + DesktopCloseBounds.headsetView, DesktopCloseBounds.totalWithHeadsetView);
      expect(DesktopCloseBounds.totalWithHeadsetView, lessThan(const Duration(seconds: 6)));
    });

    test('a refused start says why and leaves nothing on', () async {
      final page = FakePage();
      service.register(page.target);
      api.startAnswer = const XrStartResult(ok: false, reason: XrStopReason.runtimeNotAnswering);
      await service.start(HeadsetChoice.around);
      expect(service.running, isFalse);
      expect(page.calls.last, 'release');
      expect(notices.last, const HeadsetNotice(HeadsetNoticeKind.stopped, reason: XrStopReason.runtimeNotAnswering));
      expect(service.settings.runningMarker, isFalse);
    });

    test('the frame rate known later is sent; the test pattern needs no page', () async {
      final page = FakePage();
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      page.frameRate.value = 23.976;
      expect(api.rates, [23.976]);
      await service.stop();
      await service.startPattern(30);
      expect(api.starts.last.content.mode, XrHeadsetMode.pattern);
      expect(api.starts.last.content.fps, 30);
      expect(api.starts.last.content.handle, isNull);
      // A page opened meanwhile leaves the pattern on
      service.register(FakePage(handle: 11).target);
      await settle();
      expect(api.contents.last.mode, XrHeadsetMode.pattern);
    });
  });

  group('events', () {
    Future<FakePage> running() async {
      final page = FakePage();
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      await service.tick();
      page.calls.clear();
      return page;
    }

    test('play or pause and seek once each, by their sequence, even when a poll gives them again', () async {
      final page = await running();
      api.replay = true;
      api.emit(XrEventKind.playPause);
      api.emit(XrEventKind.seek, seconds: 10);
      api.emit(XrEventKind.seek, seconds: -30);
      await service.tick();
      await service.tick();
      await service.tick();
      expect(page.calls, ['playPause', 'seek 10', 'seek -30']);
    });

    test('exit stops the view and pauses', () async {
      final page = await running();
      api.emit(XrEventKind.exit);
      await service.tick();
      await settle();
      expect(page.calls, contains('pause'));
      expect(api.stops, 1);
      expect(service.running, isFalse);
    });

    test('the headset taken off pauses only with the setting on, and nothing resumes by itself', () async {
      var page = await running();
      api.emit(XrEventKind.visibility, on: false);
      await service.tick();
      expect(page.calls, ['pause']);
      expect(notices.last, const HeadsetNotice(HeadsetNoticeKind.takenOff));
      api.emit(XrEventKind.visibility, on: true);
      await service.tick();
      expect(page.calls, ['pause'], reason: 'not resumed');
      await service.stop();

      await service.settings.setPauseWhenTakenOff(false);
      page = await running();
      api.emit(XrEventKind.visibility, on: false);
      await service.tick();
      expect(page.calls, isEmpty);
    });

    test('recenter and lying down update the menu', () async {
      await running();
      api.emit(XrEventKind.lyingDown, on: true);
      await service.tick();
      expect(service.lyingDown, isTrue);
      await service.recenter();
      expect(api.recenters, [true], reason: 'recentered lying down');
      await service.setLyingDown(false);
      expect(api.recenters, [true, false]);
      expect(service.lyingDown, isFalse);
    });

    test('an end not asked from the window pauses and says why', () async {
      final page = await running();
      api
        ..running = false
        ..reason = XrStopReason.runtimeLost;
      await service.tick();
      await settle();
      expect(service.running, isFalse);
      expect(page.calls, containsAllInOrder(['release', 'pause']));
      expect(notices.last, const HeadsetNotice(HeadsetNoticeKind.stopped, reason: XrStopReason.runtimeLost));
      // The text the user reads says what happened to the video
      expect(english['headset_view_error_runtime_lost'], contains('paused'));
    });

    test('a stop the runtime does not answer says so', () async {
      await running();
      api.stopAnswer = false;
      await service.stop();
      expect(notices.last, const HeadsetNotice(HeadsetNoticeKind.stopped, reason: XrStopReason.runtimeNotAnswering));
    });
  });

  group('the crash guard', () {
    Future<HeadsetViewService> restart() async {
      final next = testService(api, folder, notices: notices);
      await next.startUp();
      return next;
    }

    test('one marker: a notice; two in a row: the switch off; a good view resets the count', () async {
      final page = FakePage();
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      // The app ends with the view running

      var next = await restart();
      expect(notices.last, const HeadsetNotice(HeadsetNoticeKind.crashOnce));
      expect(next.settings.enabled.value, isTrue);
      expect(next.settings.crashes, 1);
      next.register(page.target);
      await next.refreshRuntime();
      await next.start(HeadsetChoice.around);

      next.dispose();
      next = await restart();
      expect(notices.last, const HeadsetNotice(HeadsetNoticeKind.crashGuard));
      expect(next.settings.enabled.value, isFalse);
      expect(next.available, isFalse);

      // Turned on again by hand, then a view that ran and ended
      await next.settings.setEnabled(true);
      next.dispose();
      next = await restart();
      next.register(page.target);
      await next.start(HeadsetChoice.around);
      next.dispose();
      next = await restart();
      expect(next.settings.crashes, 1);
      next.register(page.target);
      await next.start(HeadsetChoice.around);
      await next.tick();
      await next.stop();
      expect(next.settings.crashes, 0, reason: 'a good view');
      next.dispose();
      final count = notices.length;
      next = await restart();
      expect(notices, hasLength(count), reason: 'no marker left');
      next.dispose();
    });
  });

  group('logs', () {
    test('in headset/ of the support folder, the 20 newest kept', () async {
      final settings = HeadsetViewSettings(folder: () async => folder);
      final logs = await settings.logFolder();
      expect(logs.path, p.join(folder.path, 'headset'));
      for (var i = 0; i < 25; i++) {
        File(p.join(logs.path, 'headset-20261101-1000${i.toString().padLeft(2, '0')}.log')).writeAsStringSync('');
      }
      File(p.join(logs.path, 'notes.txt')).writeAsStringSync('kept');
      final path = await settings.newLogPath(now: DateTime(2026, 11, 15, 9, 5, 7));
      expect(p.basename(path), 'headset-20261115-090507.log');
      File(path).writeAsStringSync('');
      final names = logs.listSync().map((entity) => p.basename(entity.path)).where((n) => n.endsWith('.log')).toList()
        ..sort();
      expect(names, hasLength(HeadsetViewSettings.keptLogs));
      expect(names.first, 'headset-20261101-100006.log', reason: 'the oldest went');
      expect(File(p.join(logs.path, 'notes.txt')).existsSync(), isTrue);
      final second = await settings.newLogPath(now: DateTime(2026, 11, 15, 9, 5, 7));
      expect(p.basename(second), 'headset-20261115-090507-2.log', reason: 'two views in the same second');
    });

    test('the labels of every page say the kind of video only, never a URL, a path, a token or a title', () {
      final words = RegExp(r'^[A-Za-z0-9 ,]+$');
      for (final source in HeadsetSourceKind.values) {
        for (final video in HeadsetVideoKind.values) {
          for (final mode in XrHeadsetMode.values) {
            for (final stereo in XrStereo.values) {
              for (final squeeze in XrEyeSqueeze.values) {
                final label = headsetLabel(source: source, video: video, mode: mode, stereo: stereo, squeeze: squeeze);
                expect(label, matches(words), reason: label);
              }
            }
          }
        }
      }
      // The pages' targets (Immich, NAS, Plex, local, raw): their title never reaches the label
      for (final (source, video, title) in [
        (HeadsetSourceKind.immich, HeadsetVideoKind.flat, 'https://immich.example/api/assets/1?key=secret'),
        (HeadsetSourceKind.nas, HeadsetVideoKind.flat, r'\\nas\films\Movie.3D.HSBS.mkv'),
        (HeadsetSourceKind.plex, HeadsetVideoKind.flat, 'http://127.0.0.1:41234/v/abc?token=xyz'),
        (HeadsetSourceKind.local, HeadsetVideoKind.flat, '/home/me/Videos/clip.mp4'),
        (HeadsetSourceKind.player360, HeadsetVideoKind.raw360, 'VID_20261101.insv'),
      ]) {
        final page = FakePage(source: source, video: video, title: title);
        for (final choice in page.choices) {
          final label = page.target.labelOf(choice);
          expect(label, matches(words), reason: label);
          expect(label, isNot(contains(title)));
        }
      }
    });

    test("start and stop go to the app's log with the reason and the file name, nothing of the video", () async {
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord
          .where((record) => record.loggerName == 'HeadsetView')
          .listen(records.add);
      addTearDown(subscription.cancel);
      Logger.root.level = Level.ALL;
      final page = FakePage(title: 'https://immich.example/a?key=secret');
      service.register(page.target);
      await service.start(HeadsetChoice.around);
      await service.stop();
      final lines = records.map((record) => record.message).toList();
      final name = p.basename(api.starts.single.logPath);
      expect(lines.where((line) => line.startsWith('Headset view started:')).single, contains(name));
      expect(lines.where((line) => line.startsWith('Headset view ended: stoppedByApp')).single, contains(name));
      for (final line in lines) {
        expect(line, isNot(contains('http')));
        expect(line, isNot(contains('secret')));
      }
    });

    test('the commit of the headset log is the one mobile/pubspec.yaml pins', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final refs = RegExp(
        r'url: https://github.com/immuch360/media_kit_360\s+ref: (\w+)',
      ).allMatches(pubspec).map((match) => match.group(1)).toSet();
      expect(refs, {headsetPluginCommit});
    });
  });
}
