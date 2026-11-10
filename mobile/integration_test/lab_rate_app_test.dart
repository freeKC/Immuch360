// Lab test of the invitation to rate the app (lib/domain/services/rate_app.service.dart), in the real app signed in on
// the fake Immich server of the Android lab (.github/android-lab/fake_immich.py, started by run_lab.sh), on the
// emulator of the CI, never on a device of the owner. The debug build is not from a store and the google_apis image
// has no Google Play: the store is forced to the Meta Horizon Store with a fake review API, the clock is the test's,
// and the viewings that end well are told through RateAppSignals as the viewers tell them. The rest is the app's own:
// its start, the state in the app's store, the lifecycle of the binding, the router under the timeline and the dialog.
//
//   rate-early  4 opens on 2 days and 2 viewings: no dialog, the store asked nothing, the decision says why
//   rate-due    the fifth open on the third day, more than 24 hours after the first open of the build, one more
//               viewing: the dialog shows once over the timeline; Not now; another viewing in the build: nothing
//   rate-crash  a new build that meets every other condition, and a crash of it reported by AppHealth: no dialog
//               after any number of viewings
//
// By hand, with the fake server on the computer that runs the emulator (port 2283):
//   python3 .github/android-lab/fake_immich.py --fixtures mobile/test/fixtures/android_lab \
//     --spec open-api/immich-openapi-specs.json --adb adb --serial emulator-5554 &
//   flutter test integration_test/lab_rate_app_test.dart -d emulator-5554 --flavor phone

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/rate_app.dart';
import 'package:immich_mobile/domain/services/rate_app.service.dart';
import 'package:immich_mobile/presentation/widgets/rate_app/rate_app_dialog.dart';
import 'package:immich_mobile/providers/rate_app.provider.dart';
import 'package:immich_mobile/utils/app_health.dart';
import 'package:integration_test/integration_test.dart';

import 'test_utils/lab_server.dart';

/// The clock of the invitation, moved by the test
var _now = DateTime(2026, 11, 10, 10);

/// The build number the invitation reads
var _build = 1000;

class _LabStore implements RateAppStoreApi {
  int reviews = 0;
  int pages = 0;

  @override
  Future<bool> requestReview() async {
    reviews++;
    return true;
  }

  @override
  Future<bool> openStorePage() async {
    pages++;
    return true;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('the invitation to rate: too early, due once, and held by a crash of the build', (tester) async {
    final server = LabServer.fromEnvironment();
    final store = _LabStore();
    await startLabApp(
      tester,
      overrides: [
        rateAppChannelProvider.overrideWith((ref) async => RateAppChannel.horizonStore),
        rateAppBuildProvider.overrideWith((ref) async => _build),
        rateAppClockProvider.overrideWithValue(() => _now),
        rateAppStoreApiProvider.overrideWithValue(store),
        rateAppForegroundMarkerProvider.overrideWith((ref) async => false),
      ],
    );
    await signInThroughLabServer(tester, server);
    await waitForLabTimeline(tester, server);
    final container = labContainer(tester);
    final dialog = find.byKey(RateAppDialog.dialogKey);

    RateAppService service() => RateAppSignals.service ?? fail('no invitation service registered');

    /// The service started again on [state], as at the start of the app
    Future<RateAppService> restart(RateAppState state) async {
      await container.read(rateAppMemoryProvider).write(state.encode());
      container.invalidate(rateAppBuildProvider);
      container.invalidate(rateAppServiceProvider);
      final started = await container.read(rateAppServiceProvider.future);
      return started ?? fail('the invitation did not start');
    }

    /// The app to the background for [away], the clock with it, and back
    Future<void> backgroundFor(Duration away) async {
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      _now = _now.add(away);
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(milliseconds: 500));
    }

    /// A viewing of 25 seconds of the clock that ends well, then the pause on the timeline and the decision
    Future<String?> viewing() async {
      final before = service().lastDecision;
      service().lastDecision = null;
      RateAppSignals.viewingOpened(RateAppViewing.immersive);
      _now = _now.add(const Duration(seconds: 25));
      RateAppSignals.viewingClosed(RateAppViewing.immersive);
      await pumpUntil(
        tester,
        () => service().lastDecision != null,
        reason: 'a decision after the pause on the timeline (before: $before)',
        timeout: const Duration(seconds: 20),
      );
      await tester.pump(const Duration(milliseconds: 500));
      labLog('RateApp lab: ${service().lastDecision}, ${service().state.encode()}');
      return service().lastDecision;
    }

    await labScenario('rate-early', () async {
      // A fresh state: this start is the first open
      await restart(const RateAppState());
      expect((service().state.opens, service().state.days), (1, 1));
      expect(await viewing(), 'not yet, opens 1 of 5, days 1 of 3');
      await backgroundFor(const Duration(minutes: 29));
      expect(service().state.opens, 1, reason: 'a return after 29 minutes is no open');
      await backgroundFor(const Duration(minutes: 31));
      expect(service().state.opens, 2, reason: 'a return after 31 minutes away is an open');
      // The next day, twice
      await backgroundFor(const Duration(days: 1));
      await backgroundFor(const Duration(hours: 1));
      expect((service().state.opens, service().state.days), (4, 2));
      expect(await viewing(), 'not yet, opens 4 of 5, days 2 of 3');
      expect(dialog, findsNothing);
      expect((store.reviews, store.pages), (0, 0));
    });

    await labScenario('rate-due', () async {
      // The third day, more than 24 hours after the first open of the build
      await backgroundFor(const Duration(days: 1));
      expect((service().state.opens, service().state.days, service().state.successes), (5, 3, 2));
      RateAppSignals.viewingOpened(RateAppViewing.immersive);
      _now = _now.add(const Duration(seconds: 25));
      RateAppSignals.viewingClosed(RateAppViewing.immersive);
      await pumpUntil(tester, () => dialog.evaluate().isNotEmpty, reason: 'the invitation over the timeline');
      expect(dialog, findsOneWidget);
      expect(service().lastDecision, 'due');
      await tester.tap(find.byKey(RateAppDialog.notNowKey));
      await pumpUntil(tester, () => dialog.evaluate().isEmpty, reason: 'the invitation closed by Not now');
      await pumpUntil(
        tester,
        () => service().state.asks.isNotEmpty,
        reason: 'the answer kept',
        timeout: const Duration(seconds: 10),
      );
      expect(service().state.asks.single.answer, RateAppAnswer.notNow);
      expect((store.reviews, store.pages), (0, 0));
      // Kept in the app's store, as the next start reads it
      final kept = RateAppState.decode(container.read(rateAppMemoryProvider).read());
      expect(kept.asks.single.answer, RateAppAnswer.notNow);
      expect(await viewing(), 'asked in this build');
      expect(dialog, findsNothing);
    });

    await labScenario('rate-crash', () async {
      _build = 1001;
      final day = _now;
      await restart(
        RateAppState(
          opens: kRateAppMinOpens,
          days: kRateAppMinDays,
          lastDay: rateAppDayOf(day),
          successes: kRateAppMinSuccesses,
          build: _build,
          buildSince: day.subtract(const Duration(days: 2)),
        ),
      );
      expect(service().build, 1001);
      // A crash of this build, told as AppHealth.kt reports it at the start after it
      final written = AppHealthReports.write({
        'kind': 'exit',
        'text':
            'The app ended on 2026-11-13 09:12:00: crash, in the foreground, memory PSS 312 MB, RSS 401 MB '
            '[Immuch360 $_build phone]\nLast known state: page=TabShellRoute fg',
      });
      expect(written, isTrue);
      expect(service().state.problemBuild, _build);
      for (var i = 0; i < 3; i++) {
        _now = _now.add(const Duration(minutes: 1));
        expect(await viewing(), 'a crash in this build');
        expect(dialog, findsNothing);
      }
      expect((store.reviews, store.pages), (0, 0));
    });

    await waitForQuietSyncs(tester);
  });
}
