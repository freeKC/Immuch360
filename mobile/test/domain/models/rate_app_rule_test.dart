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
  bool remoteControl = false,
  bool appOutOfDate = false,
  bool sessionTrouble = false,
}) => RateAppContext(
  channel: channel,
  build: build,
  now: now ?? _now,
  enabled: enabled,
  screenshotMode: screenshotMode,
  kioskActive: kioskActive,
  remoteControl: remoteControl,
  appOutOfDate: appOutOfDate,
  sessionTrouble: sessionTrouble,
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
    test('asks on the happy path: 4 opens on 3 days, 2 viewings, 24 hours after the first open of the build', () {
      expect(rateAppBlocker(_due(), _context()), isNull);
    });

    test('each condition blocks alone', () {
      final cases = <String, (RateAppState, RateAppContext)>{
        '3 opens': (_due().copyWith(opens: 3), _context()),
        '2 days': (_due().copyWith(days: 2), _context()),
        '1 viewing': (_due().copyWith(successes: 1), _context()),
        'a crash 2 days ago': (
          _due().copyWith(problemBuild: _build - 1, problemAt: _now.subtract(const Duration(days: 2))),
          _context(),
        ),
        'an error in this session': (_due(), _context(sessionTrouble: true)),
        'an update 23 hours ago': (_due().copyWith(buildSince: _now.subtract(const Duration(hours: 23))), _context()),
        'What\'s new 23 hours ago': (_due().copyWith(noticeAt: _now.subtract(const Duration(hours: 23))), _context()),
        'the app out of date for the server': (_due(), _context(appOutOfDate: true)),
        'asked in this build': (_due().copyWith(asks: [_ask(build: _build)]), _context()),
        'no thanks once': (_due().copyWith(asks: [_ask(answer: RateAppAnswer.noThanks)]), _context()),
        'rated': (_due().copyWith(asks: [_ask(answer: RateAppAnswer.rate)]), _context()),
        'the store page opened from Settings': (
          _due().copyWith(rateOpenedAt: _now.subtract(const Duration(days: 300))),
          _context(),
        ),
        'asked three times already': (
          _due().copyWith(
            asks: [
              _ask(build: 1, at: _now.subtract(const Duration(days: 400))),
              _ask(build: 2, at: _now.subtract(const Duration(days: 300))),
              _ask(build: 3),
            ],
          ),
          _context(),
        ),
        'the last ask 59 days ago': (
          _due().copyWith(asks: [_ask(at: _now.subtract(const Duration(days: 59)))]),
          _context(),
        ),
        'kiosk mode': (_due(), _context(kioskActive: true)),
        'the remote control layout': (_due(), _context(remoteControl: true)),
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

    test('a crash of this build three days ago no longer holds it: the heavy users meet a crash now and then', () {
      final state = _due().copyWith(problemBuild: _build, problemAt: _now.subtract(kRateAppQuietAfterCrash));
      expect(rateAppBlocker(state, _context()), isNull);
    });

    test('another ask 60 days after one left unanswered, and a third one 60 days after that', () {
      final first = _ask(build: 1, at: _now.subtract(const Duration(days: 120)));
      final second = _ask(build: 2, at: _now.subtract(kRateAppAskInterval));
      expect(rateAppBlocker(_due().copyWith(asks: [first]), _context()), isNull);
      expect(rateAppBlocker(_due().copyWith(asks: [first, second]), _context()), isNull);
    });

    test('the store prompts of Play and the App Store follow the same rule', () {
      expect(rateAppBlocker(_due(), _context(channel: RateAppChannel.googlePlay)), isNull);
      expect(rateAppBlocker(_due(), _context(channel: RateAppChannel.appStore)), isNull);
    });

    test('the log line says what is missing', () {
      expect(rateAppBlocker(_due().copyWith(opens: 3, days: 2), _context()), 'not yet, opens 3 of 4, days 2 of 3');
      expect(rateAppBlocker(_due().copyWith(successes: 1), _context()), 'not yet, viewings 1 of 2');
      expect(
        rateAppBlocker(_due().copyWith(problemAt: _now.subtract(const Duration(hours: 47))), _context()),
        'a crash 47 h ago',
      );
      expect(rateAppBlocker(_due(), _context(sessionTrouble: true)), 'an error in this session');
      expect(rateAppBlocker(_due().copyWith(asks: [_ask(answer: RateAppAnswer.noThanks)]), _context()), 'no thanks');
      expect(rateAppBlocker(_due(), _context(remoteControl: true)), 'remote control layout');
    });

    test('the channels that can ask', () {
      expect(RateAppChannel.values.where((channel) => channel.canAsk), [
        RateAppChannel.googlePlay,
        RateAppChannel.appStore,
        RateAppChannel.horizonStore,
      ]);
    });

    test('every viewing but a film may be the moment', () {
      expect(RateAppViewing.values.where((kind) => !kind.isMoment), [RateAppViewing.film]);
    });
  });

  group('the answers', () {
    test('an answer goes to the unanswered ask of this build, and only to it', () {
      final waiting = _due().copyWith(
        asks: [
          _ask(build: 1),
          _ask(build: _build, at: _now),
        ],
      );
      final rated = rateAppAnswered(waiting, build: _build, answer: RateAppAnswer.rate);
      expect(rated.asks.map((ask) => ask.answer), [RateAppAnswer.none, RateAppAnswer.rate]);
      expect(rated.asks.last.at, _now);
      expect(rated.rated, isTrue);
      // Already answered, or an ask of another build: nothing changes
      expect(rateAppAnswered(rated, build: _build, answer: RateAppAnswer.noThanks), rated);
      expect(rateAppAnswered(waiting, build: _build + 1, answer: RateAppAnswer.rate), waiting);
      expect(rateAppAnswered(_due(), build: _build, answer: RateAppAnswer.rate), _due());
    });

    test('the line of the Quest store build waits in Settings while the ask of this build has no answer', () {
      final waiting = _due().copyWith(
        asks: [_ask(build: _build, at: _now)],
      );
      bool waits(RateAppState state, {RateAppChannel channel = RateAppChannel.horizonStore, int build = _build}) =>
          rateAppLineWaits(state, channel: channel, build: build);
      expect(waits(waiting), isTrue);
      expect(waits(_due()), isFalse);
      expect(waits(waiting, build: _build + 1), isFalse, reason: 'gone with the update');
      expect(waits(waiting, channel: RateAppChannel.googlePlay), isFalse, reason: 'Play shows its own card');
      expect(waits(rateAppAnswered(waiting, build: _build, answer: RateAppAnswer.noThanks)), isFalse);
      expect(waits(rateAppAnswered(waiting, build: _build, answer: RateAppAnswer.rate)), isFalse);
      expect(waits(waiting.copyWith(rateOpenedAt: _now)), isFalse, reason: 'rated from Settings');
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
          _ask(answer: RateAppAnswer.noThanks),
          _ask(build: _build, at: _now),
        ],
        rateOpenedAt: DateTime(2026, 11, 3, 9),
      );
      final back = RateAppState.decode(state.encode());
      expect(back, state);
      expect(back.asks, state.asks);
      expect(back.rateOpenedAt, DateTime(2026, 11, 3, 9));
      expect((back.declined, back.rated), (true, true));
    });

    test('the Not now kept by the builds 45 to 50 reads as No thanks', () {
      final state = RateAppState.decode(
        '{"v": 1, "opens": 9, "asks": [{"build": 3030045, "at": 0, "channel": "horizonStore", "answer": "notNow"}]}',
      );
      expect(state.asks.single.answer, RateAppAnswer.noThanks);
      expect(state.declined, isTrue);
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

    test('the time the process ended, in local time', () {
      expect(rateAppExitTime(_exit('crash')), DateTime(2026, 11, 10, 22, 40, 1));
      expect(rateAppExitTime('The main thread did not answer for 5.0 s, in Java code.'), isNull);
    });

    test('the build that ran', () {
      expect(rateAppExitBuild(_exit('crash')), 3030043);
      expect(rateAppExitBuild(_exit('crash', build: 'build not recorded, now 3030043 quest')), isNull);
    });
  });
}
