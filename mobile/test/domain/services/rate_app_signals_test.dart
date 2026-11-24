import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';

const _build = 3030043;

class _Memory {
  String? text;
  int writes = 0;

  RateAppMemory get memory => RateAppMemory(
    read: () => text,
    write: (value) async {
      text = value;
      writes++;
    },
  );
}

class _Store implements RateAppStoreApi {
  int reviews = 0;
  int pages = 0;

  @override
  Future<bool> requestReview() async {
    reviews++;
    return true;
  }

  bool opens = true;

  @override
  Future<bool> openStorePage() async {
    pages++;
    return opens;
  }
}

class _Screen implements RateAppScreen {
  @override
  bool browsing = true;

  @override
  bool kioskActive = false;

  @override
  bool remoteControl = false;

  @override
  bool appOutOfDate = false;

  bool lineShows = true;
  int lines = 0;

  @override
  Future<bool> showLine() async {
    lines++;
    return lineShows;
  }

  int hides = 0;

  @override
  void hideLine() => hides++;
}

/// A state that waits for one more viewing that ends well at [now]
String _almostDue(DateTime now) => RateAppState(
  opens: kRateAppMinOpens - 1,
  days: kRateAppMinDays,
  lastDay: rateAppDayOf(now),
  successes: kRateAppMinSuccesses - 1,
  build: _build,
  buildSince: now.subtract(const Duration(days: 3)),
).encode();

void main() {
  late DateTime now;
  late _Memory memory;
  late _Store store;
  late _Screen screen;

  setUp(() {
    now = DateTime(2026, 11, 20, 18);
    memory = _Memory();
    store = _Store();
    screen = _Screen();
    RateAppSignals.resetForTest();
  });

  tearDown(RateAppSignals.resetForTest);

  RateAppService service({
    RateAppChannel channel = RateAppChannel.horizonStore,
    int build = _build,
    bool marker = false,
  }) => RateAppService(
    channel: channel,
    build: build,
    memory: memory.memory,
    store: store,
    screen: screen,
    now: () => now,
    useForegroundMarker: marker,
  );

  /// Runs [body] with a fake clock for the timers, [now] moving with it
  void run(void Function(FakeAsync async, void Function(Duration) wait) body) => fakeAsync((async) {
    void wait(Duration duration) {
      now = now.add(duration);
      async.elapse(duration);
    }

    body(async, wait);
    async.flushMicrotasks();
  });

  test('a start counts an open, and a return after 30 minutes another one, after 29 not', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      async.flushMicrotasks();
      expect(rate.state.opens, 1);
      rate.paused();
      wait(const Duration(minutes: 29));
      rate.resumed();
      expect(rate.state.opens, 1);
      rate.paused();
      wait(const Duration(minutes: 31));
      rate.resumed();
      expect(rate.state.opens, 2);
      async.flushMicrotasks();
      expect(RateAppState.decode(memory.text).opens, 2);
    });
  });

  test('time in a native viewer over the app is not time away', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.viewingOpened(RateAppViewing.immersive);
      rate.paused();
      wait(const Duration(minutes: 40));
      rate.resumed();
      expect(rate.state.opens, 1);
    });
  });

  test('time on the 360° photo page of the app is time away', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.viewingOpened(RateAppViewing.panorama);
      rate.paused();
      wait(const Duration(minutes: 40));
      rate.resumed();
      expect(rate.state.opens, 2);
    });
  });

  test('the immersive viewer closed after 25 seconds counts, after 5 seconds not', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.viewingOpened(RateAppViewing.immersive);
      wait(const Duration(seconds: 5));
      rate.viewingClosed(RateAppViewing.immersive);
      expect(rate.state.successes, 0);
      rate.viewingOpened(RateAppViewing.immersive);
      wait(const Duration(seconds: 25));
      rate.viewingClosed(RateAppViewing.immersive);
      expect(rate.state.successes, 1);
    });
  });

  test('a splat viewer gone with its renderer does not count', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.viewingOpened(RateAppViewing.splat);
      wait(const Duration(minutes: 2));
      rate.viewingClosed(RateAppViewing.splat, normal: false);
      expect(rate.state.successes, 0);
    });
  });

  test('a film turned watched counts, once with the closing of its viewer', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.film);
      expect(rate.state.successes, 1);
      rate.viewingOpened(RateAppViewing.immersive);
      wait(const Duration(minutes: 3));
      rate.succeeded(RateAppViewing.film);
      rate.viewingClosed(RateAppViewing.immersive);
      expect(rate.state.successes, 2);
    });
  });

  test('a video that could not play spoils the viewing open', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.viewingOpened(RateAppViewing.sphericalVideo);
      rate.videoProblem();
      wait(const Duration(minutes: 1));
      rate.viewingClosed(RateAppViewing.sphericalVideo);
      expect(rate.state.successes, 0);
    });
  });

  test('a crash report is kept with the time of the crash, a low memory kill is not kept', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.exitReported(
        'The app ended on 2026-11-19 22:40:01: killed for low memory, in the foreground [Immuch360 $_build quest]',
      );
      expect(rate.state.problemBuild, isNull);
      rate.exitReported('The app ended on 2026-11-19 22:40:01: native crash, visible [Immuch360 $_build quest]');
      expect((rate.state.problemBuild, rate.state.problemAt), (_build, DateTime(2026, 11, 19, 22, 40, 1)));
      // An older report read later keeps the latest crash; a time ahead of the clock is now
      rate.exitReported('The app ended on 2026-11-12 08:00:00: crash, in the foreground [Immuch360 3030042 quest]');
      expect(rate.state.problemAt, DateTime(2026, 11, 19, 22, 40, 1));
      rate.exitReported('The app ended on 2026-12-25 08:00:00: crash, in the foreground [Immuch360 $_build quest]');
      expect(rate.state.problemAt, now);
    });
  });

  test('a crash of the last days holds the ask, one of four days ago does not', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      rate.exitReported('The app ended on 2026-11-18 18:00:00: crash, in the foreground [Immuch360 $_build quest]');
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'a crash 48 h ago');
      expect(screen.lines, 0);
    });
    run((async, wait) {
      memory = _Memory()..text = _almostDue(now);
      screen = _Screen();
      final rate = service();
      unawaited(rate.start());
      rate.exitReported('The app ended on 2026-11-16 17:00:00: crash, in the foreground [Immuch360 $_build quest]');
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'due');
    });
  });

  test('a video that could not play holds the ask for the session, and the next session may ask', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      rate.videoProblem();
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'an error in this session');
      rate.paused();
      wait(const Duration(minutes: 31));
      rate.resumed();
      rate.succeeded(RateAppViewing.sphericalVideo);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'due');
      expect(screen.lines, 1);
    });
  });

  test('a viewer that ended on an error holds the ask for the session', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      rate.viewingOpened(RateAppViewing.splat);
      wait(const Duration(minutes: 2));
      rate.viewingClosed(RateAppViewing.splat, normal: false);
      rate.succeeded(RateAppViewing.panorama);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'an error in this session');
    });
  });

  test('the foreground marker left set tells a crash of the build that ran', () {
    run((async, wait) {
      memory.text = const RateAppState(build: 3030042, foreground: true).encode();
      final rate = service(marker: true);
      unawaited(rate.start());
      async.flushMicrotasks();
      expect(rate.state.problemBuild, 3030042);
      expect(rate.state.foreground, isTrue);
      rate.paused();
      expect(rate.state.foreground, isFalse);
      rate.resumed();
      expect(rate.state.foreground, isTrue);
    });
  });

  test('without the marker, a set flag is not read as a crash', () {
    run((async, wait) {
      memory.text = const RateAppState(build: _build, foreground: true).encode();
      final rate = service();
      unawaited(rate.start());
      expect(rate.state.problemBuild, isNull);
    });
  });

  test('the Quest store build: the quiet line after the pause on a browse page, once; it waits in Settings', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      expect(rate.line.value, isFalse);
      rate.viewingOpened(RateAppViewing.immersive);
      wait(const Duration(seconds: 30));
      rate.viewingClosed(RateAppViewing.immersive);
      wait(const Duration(seconds: 1));
      expect(screen.lines, 0);
      wait(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(screen.lines, 1);
      expect(rate.lastDecision, 'due');
      expect((store.reviews, store.pages), (0, 0));
      expect(rate.state.asks.single.answer, RateAppAnswer.none);
      expect(rate.line.value, isTrue, reason: 'the line waits in Settings');
      // Another viewing in the same build: nothing more
      rate.viewingOpened(RateAppViewing.immersive);
      wait(const Duration(seconds: 30));
      rate.viewingClosed(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(screen.lines, 1);
      expect(rate.lastDecision, 'asked in this build');
    });
  });

  test('the line still waits at the next start of the build, and leaves with the update', () {
    run((async, wait) {
      memory.text = rateAppAsked(
        RateAppState.decode(_almostDue(now)),
        RateAppAsk(build: _build, at: now, channel: RateAppChannel.horizonStore),
      ).encode();
      final again = service();
      unawaited(again.start());
      async.flushMicrotasks();
      expect(again.line.value, isTrue);
      final updated = service(build: _build + 1);
      unawaited(updated.start());
      async.flushMicrotasks();
      expect(updated.line.value, isFalse);
    });
  });

  test('No thanks on the line ends the invitation for good', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      unawaited(rate.answer(RateAppAnswer.noThanks));
      async.flushMicrotasks();
      expect(rate.line.value, isFalse);
      expect(RateAppState.decode(memory.text).declined, isTrue);
      expect(store.pages, 0);
      // Months later, in another build: never again
      now = now.add(const Duration(days: 200));
      final later = service(build: _build + 5);
      unawaited(later.start());
      later.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(later.lastDecision, 'no thanks');
      expect(screen.lines, 1);
    });
  });

  test('Rate on the line opens the store page and ends the invitation', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.panorama);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      unawaited(rate.answer(RateAppAnswer.rate));
      async.flushMicrotasks();
      expect((screen.lines, store.pages), (1, 1));
      expect(rate.state.rated, isTrue);
      expect(rate.line.value, isFalse);
    });
  });

  test('Rate on the line whose store page did not open: not kept, the line still waits', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      store.opens = false;
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.panorama);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      bool? kept;
      unawaited(rate.answer(RateAppAnswer.rate).then((value) => kept = value));
      async.flushMicrotasks();
      expect((kept, store.pages), (false, 1));
      expect(rate.state.rated, isFalse);
      expect(RateAppState.decode(memory.text).rated, isFalse);
      expect(rate.line.value, isTrue, reason: 'the line waits in Settings for another try');
    });
  });

  test('the line is taken away as a viewing opens or the app leaves the browse page', () {
    run((async, wait) {
      final rate = service();
      unawaited(rate.start());
      rate.pageShown();
      expect(screen.hides, 0, reason: 'still on a browse page');
      screen.browsing = false;
      rate.pageShown();
      expect(screen.hides, 1);
      rate.viewingOpened(RateAppViewing.panorama);
      expect(screen.hides, 2);
    });
  });

  test('a line that could not show is no ask', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      screen.lineShows = false;
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(screen.lines, 1);
      expect(rate.state.asks, isEmpty);
      expect(rate.line.value, isFalse);
    });
  });

  test('a film counts among the viewings but is not the moment', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.film);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.state.successes, kRateAppMinSuccesses);
      expect((rate.lastDecision, screen.lines), (null, 0));
      wait(const Duration(seconds: 10));
      rate.succeeded(RateAppViewing.spatialVideo);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect((rate.lastDecision, screen.lines), ('due', 1));
    });
  });

  test('Rate Immuch360 in Settings opens the store page, and nothing is asked again', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      final rate = service(channel: RateAppChannel.googlePlay);
      unawaited(rate.start());
      unawaited(rate.rateFromSettings());
      async.flushMicrotasks();
      expect((store.pages, store.reviews), (1, 0));
      expect(RateAppState.decode(memory.text).rateOpenedAt, now);
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'rated already');
      expect(store.reviews, 0);
    });
  });

  test('Rate Immuch360 in Settings whose page did not open changes nothing: the ask still comes', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      store.opens = false;
      final rate = service(channel: RateAppChannel.googlePlay);
      unawaited(rate.start());
      bool? opened;
      unawaited(rate.rateFromSettings().then((value) => opened = value));
      async.flushMicrotasks();
      expect((opened, store.pages), (false, 1));
      expect(RateAppState.decode(memory.text).rateOpenedAt, isNull);
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'due');
      expect(store.reviews, 1);
    });
  });

  test('Google Play and the App Store: their prompt, no dialog, counted as asked', () {
    for (final channel in [RateAppChannel.googlePlay, RateAppChannel.appStore]) {
      run((async, wait) {
        memory = _Memory()..text = _almostDue(now);
        store = _Store();
        screen = _Screen();
        final rate = service(channel: channel);
        unawaited(rate.start());
        rate.succeeded(RateAppViewing.panorama);
        wait(kRateAppSettle);
        async.flushMicrotasks();
        expect((screen.lines, store.reviews), (0, 1), reason: channel.name);
        expect(rate.line.value, isFalse, reason: channel.name);
        expect(rate.state.asks.single.answer, RateAppAnswer.none, reason: channel.name);
        expect(rate.state.asks.single.channel, channel, reason: channel.name);
      });
    }
  });

  test('not on a browse page: waits for one, then asks after the pause', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      screen.browsing = false;
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.immersive);
      wait(const Duration(seconds: 10));
      expect(screen.lines, 0);
      screen.browsing = true;
      rate.pageShown();
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(screen.lines, 1);
    });
  });

  test('early: opens 3 of 4, nothing asked, the decision says why', () {
    run((async, wait) {
      memory.text = RateAppState(
        opens: 2,
        days: 1,
        lastDay: rateAppDayOf(now),
        build: _build,
        buildSince: now.subtract(const Duration(days: 3)),
      ).encode();
      final rate = service();
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(screen.lines, 0);
      expect(rate.lastDecision, 'not yet, opens 3 of 4, days 1 of 3');
    });
  });

  test('the kiosk, the remote control layout and an app too old for the server hold the ask', () {
    run((async, wait) {
      memory.text = _almostDue(now);
      screen.kioskActive = true;
      final rate = service(channel: RateAppChannel.googlePlay);
      unawaited(rate.start());
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'kiosk mode');
      screen
        ..kioskActive = false
        ..remoteControl = true;
      wait(const Duration(seconds: 10));
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'remote control layout');
      screen
        ..remoteControl = false
        ..appOutOfDate = true;
      wait(const Duration(seconds: 10));
      rate.succeeded(RateAppViewing.immersive);
      wait(kRateAppSettle);
      async.flushMicrotasks();
      expect(rate.lastDecision, 'the app is out of date for the server');
      expect((screen.lines, store.reviews), (0, 0));
    });
  });

  test('the signals reach the service registered, and wait for it', () {
    run((async, wait) {
      RateAppSignals.viewingOpened(RateAppViewing.immersive);
      RateAppSignals.exitReported('The app ended on 2026-11-10 22:40:01: crash, in the foreground [Immuch360 7 quest]');
      RateAppSignals.noticeShown();
      final rate = service();
      unawaited(rate.start());
      async.flushMicrotasks();
      RateAppSignals.register(rate);
      expect(rate.state.problemBuild, 7);
      expect(rate.state.noticeAt, now);
      RateAppSignals.viewingOpened(RateAppViewing.immersive);
      wait(const Duration(seconds: 30));
      RateAppSignals.viewingClosed(RateAppViewing.immersive);
      expect(rate.state.successes, 1);
      RateAppSignals.register(null);
      RateAppSignals.succeeded(RateAppViewing.film);
      expect(rate.state.successes, 1);
    });
  });

  test('an unreadable state starts again', () {
    run((async, wait) {
      memory.text = 'not json';
      final rate = service();
      unawaited(rate.start());
      async.flushMicrotasks();
      expect(rate.state.opens, 1);
      expect(RateAppState.decode(memory.text).opens, 1);
    });
  });
}
