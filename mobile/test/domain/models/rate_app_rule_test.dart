import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';

const _build = 3030043;

final _now = DateTime(2026, 11, 20, 18);

/// A state that meets every condition of the rule at [_now] in [_build]
RateAppState _due() => RateAppState(
  opens: kRateAppMinOpens,
  days: kRateAppMinDays,
  lastDay: '2026-11-20',
  successes: kRateAppMinSuccesses,
  build: _build,
  buildSince: _now.subtract(kRateAppQuietAfterUpdate),
);

RateAppContext _context({
  RateAppChannel channel = RateAppChannel.horizonStore,
  int build = _build,
  DateTime? now,
  bool enabled = true,
  bool screenshotMode = false,
  bool kioskActive = false,
  bool versionWarning = false,
}) => RateAppContext(
  channel: channel,
  build: build,
  now: now ?? _now,
  enabled: enabled,
  screenshotMode: screenshotMode,
  kioskActive: kioskActive,
  versionWarning: versionWarning,
);

RateAppAsk _ask({int build = 3030040, DateTime? at, RateAppAnswer answer = RateAppAnswer.none}) => RateAppAsk(
  build: build,
  at: at ?? _now.subtract(const Duration(days: 200)),
  channel: RateAppChannel.horizonStore,
  answer: answer,
);

/// The text describeExit of AppHealth.kt writes for an end
String _exit(String reason, {String where = ', in the foreground', String build = '3030043 quest'}) =>
    'The app ended on 2026-11-10 22:40:01: $reason$where, memory PSS 312 MB, RSS 401 MB [Immuch360 $build]\n'
    'Last known state: page=TabShellRoute fg';

void main() {
  group('the rule', () {
    test('asks on the happy path: 5 opens on 3 days, 2 viewings, 24 hours after the first open of the build', () {
      expect(rateAppBlocker(_due(), _context()), isNull);
    });

    test('each condition blocks alone', () {
      final cases = <String, (RateAppState, RateAppContext)>{
        '4 opens': (_due().copyWith(opens: 4), _context()),
        '2 days': (_due().copyWith(days: 2), _context()),
        '1 viewing': (_due().copyWith(successes: 1), _context()),
        'a crash in this build': (_due().copyWith(problemBuild: _build, problemAt: _now), _context()),
        'an update 23 hours ago': (_due().copyWith(buildSince: _now.subtract(const Duration(hours: 23))), _context()),
        'What\'s new 23 hours ago': (_due().copyWith(noticeAt: _now.subtract(const Duration(hours: 23))), _context()),
        'the version warning': (_due(), _context(versionWarning: true)),
        'asked in this build': (_due().copyWith(asks: [_ask(build: _build)]), _context()),
        'dismissed twice': (
          _due().copyWith(
            asks: [
              _ask(build: 1, answer: RateAppAnswer.notNow),
              _ask(build: 2, answer: RateAppAnswer.notNow),
            ],
          ),
          _context(),
        ),
        'rated': (_due().copyWith(asks: [_ask(answer: RateAppAnswer.rate)]), _context()),
        'asked twice already': (_due().copyWith(asks: [_ask(build: 1), _ask(build: 2)]), _context()),
        'second ask at 89 days': (
          _due().copyWith(asks: [_ask(at: _now.subtract(const Duration(days: 89)))]),
          _context(),
        ),
        'kiosk mode': (_due(), _context(kioskActive: true)),
        'store captures': (_due(), _context(screenshotMode: true)),
        'the switch off': (_due(), _context(enabled: false)),
        'the GitHub builds': (_due(), _context(channel: RateAppChannel.github)),
        'no store': (_due(), _context(channel: RateAppChannel.none)),
        'a state of another build': (_due(), _context(build: _build + 1)),
      };
      for (final MapEntry(key: name, value: (state, context)) in cases.entries) {
        expect(rateAppBlocker(state, context), isNotNull, reason: name);
      }
    });

    test('a crash of an earlier build does not block the build that fixes it', () {
      expect(rateAppBlocker(_due().copyWith(problemBuild: _build - 1, problemAt: _now), _context()), isNull);
    });

    test('a second ask 90 days after a first one left unanswered', () {
      final state = _due().copyWith(asks: [_ask(at: _now.subtract(kRateAppSecondAskAfter))]);
      expect(rateAppBlocker(state, _context()), isNull);
    });

    test('one dismissal leaves one more ask, later', () {
      final state = _due().copyWith(asks: [_ask(answer: RateAppAnswer.notNow)]);
      expect(rateAppBlocker(state, _context()), isNull);
    });

    test('the store prompts of Play and the App Store follow the same rule', () {
      expect(rateAppBlocker(_due(), _context(channel: RateAppChannel.googlePlay)), isNull);
      expect(rateAppBlocker(_due(), _context(channel: RateAppChannel.appStore)), isNull);
    });

    test('the log line says what is missing', () {
      expect(rateAppBlocker(_due().copyWith(opens: 4, days: 2), _context()), 'not yet, opens 4 of 5, days 2 of 3');
      expect(rateAppBlocker(_due().copyWith(successes: 1), _context()), 'not yet, viewings 1 of 2');
      expect(rateAppBlocker(_due().copyWith(problemBuild: _build), _context()), 'a crash in this build');
    });

    test('the channels that can ask', () {
      expect(RateAppChannel.values.where((channel) => channel.canAsk), [
        RateAppChannel.googlePlay,
        RateAppChannel.appStore,
        RateAppChannel.horizonStore,
      ]);
    });
  });

  group('the opens', () {
    test('count the days by the local day, a later one only', () {
      var state = const RateAppState();
      state = rateAppOpened(state, now: DateTime(2026, 11, 10, 23, 59), build: _build);
      state = rateAppOpened(state, now: DateTime(2026, 11, 10, 23, 59, 30), build: _build);
      expect((state.opens, state.days), (2, 1));
      // Past midnight
      state = rateAppOpened(state, now: DateTime(2026, 11, 11, 0, 0, 1), build: _build);
      expect((state.opens, state.days, state.lastDay), (3, 2, '2026-11-11'));
      // A change of time zone that brings back the day before counts no new day
      state = rateAppOpened(state, now: DateTime(2026, 11, 10, 22), build: _build);
      expect((state.opens, state.days, state.lastDay), (4, 2, '2026-11-11'));
    });

    test('the first open of a new build starts its quiet period, the next ones keep it', () {
      final first = DateTime(2026, 11, 10, 9);
      var state = rateAppOpened(const RateAppState(), now: first, build: 1);
      state = rateAppOpened(state, now: first.add(const Duration(hours: 3)), build: 1);
      expect((state.build, state.buildSince), (1, first));
      final update = first.add(const Duration(days: 2));
      state = rateAppOpened(state, now: update, build: 2);
      expect((state.build, state.buildSince), (2, update));
    });

    test('a viewing counts from 20 seconds and when it ended normally', () {
      expect(rateAppViewingCounts(const Duration(seconds: 19)), isFalse);
      expect(rateAppViewingCounts(const Duration(seconds: 20)), isTrue);
      expect(rateAppViewingCounts(const Duration(minutes: 5), normal: false), isFalse);
    });
  });

  group('the state', () {
    test('goes through JSON and back', () {
      final state = _due().copyWith(
        noticeAt: DateTime(2026, 11, 1, 12),
        problemBuild: 3030042,
        problemAt: DateTime(2026, 11, 2, 8),
        foreground: true,
        asks: [
          _ask(answer: RateAppAnswer.notNow),
          _ask(build: _build, at: _now),
        ],
      );
      final back = RateAppState.decode(state.encode());
      expect(back, state);
      expect(back.asks, state.asks);
      expect(back.dismissals, 1);
    });

    test('an unreadable text is a fresh state, told', () {
      final errors = <Object>[];
      expect(RateAppState.decode('{"opens": "five"', onError: errors.add), const RateAppState());
      expect(RateAppState.decode('[1, 2]', onError: errors.add), const RateAppState());
      expect(RateAppState.decode('{"asks": [{"build": 1}]}', onError: errors.add), const RateAppState());
      expect(errors, hasLength(3));
      expect(RateAppState.decode(null), const RateAppState());
      expect(RateAppState.decode(''), const RateAppState());
    });

    test('a state without the optional fields reads with their defaults', () {
      final state = RateAppState.decode('{"v": 1, "opens": 3}');
      expect((state.opens, state.days, state.successes, state.foreground), (3, 0, 0, false));
      expect(state.asks, isEmpty);
    });
  });

  group('the exit reports', () {
    test('a crash, a native crash, an ANR and the crash signals count', () {
      for (final reason in [
        'crash',
        'native crash',
        'not responding (ANR)',
        'a native abort (signal 6, SIGABRT): a native library stopped the app',
        'a native crash (signal 11, SIGSEGV)',
        'killed by signal 4',
        'killed by signal 7',
        'killed by signal 8',
      ]) {
        expect(rateAppExitIsCrash(_exit(reason)), isTrue, reason: reason);
      }
    });

    test('a crash with the description Android gave counts', () {
      expect(rateAppExitIsCrash(_exit('crash (java.lang.IllegalStateException)')), isTrue);
    });

    test('a kill for low memory, by SIGKILL or for resources does not count', () {
      for (final reason in [
        'killed for low memory',
        'killed by signal 9 (SIGKILL, often the low memory killer)',
        'killed by a signal',
        'killed by signal 15',
        'killed for excessive resource use',
        'a process it depends on died',
      ]) {
        expect(rateAppExitIsCrash(_exit(reason)), isFalse, reason: reason);
      }
    });

    test('a crash in the foreground or visible counts, in the background not', () {
      expect(rateAppExitIsCrash(_exit('crash', where: ', in the foreground, screen off')), isTrue);
      expect(rateAppExitIsCrash(_exit('crash', where: ', visible')), isTrue);
      expect(rateAppExitIsCrash(_exit('crash', where: '')), isTrue);
      expect(rateAppExitIsCrash(_exit('crash', where: ', in the background, cached')), isFalse);
      expect(rateAppExitIsCrash(_exit('crash', where: ', running a foreground service')), isFalse);
    });

    test('another text is no crash', () {
      expect(rateAppExitIsCrash('The main thread did not answer for 5.0 s, in Java code.'), isFalse);
      expect(rateAppExitIsCrash(''), isFalse);
    });

    test('the build that ran', () {
      expect(rateAppExitBuild(_exit('crash')), 3030043);
      expect(rateAppExitBuild(_exit('crash', build: 'build not recorded, now 3030043 quest')), isNull);
    });
  });
}
