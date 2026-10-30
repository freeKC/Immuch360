// The accelerated seek of a TV video: a quick series of left or right presses moves 10 s, then 30 s, then 60 s per
// press, and the next press moves 10 s again once 1.5 s went by without a press. From the design note of Michael
// Cloutier (mlc70) on the Android TV viewer controls.

import 'package:easy_localization/easy_localization.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_seek_series.dart';

void main() {
  const pause = Duration(milliseconds: 500);

  test('the steps: 10 s, then 30 s, then 60 s for every press after', () {
    expect(remoteSeekSeriesStep(1), const Duration(seconds: 10));
    expect(remoteSeekSeriesStep(2), const Duration(seconds: 30));
    expect(remoteSeekSeriesStep(3), const Duration(seconds: 60));
    expect(remoteSeekSeriesStep(4), const Duration(seconds: 60));
    expect(remoteSeekSeriesStep(40), const Duration(seconds: 60));
    expect(remoteSeekSeriesWindow, const Duration(milliseconds: 1500));
  });

  test('a quick series of presses goes further at each press, forward and back', () {
    fakeAsync((async) {
      final series = RemoteSeekSeries();
      final moves = <Duration>[];
      for (var i = 0; i < 5; i++) {
        moves.add(series.press(forward: true));
        async.elapse(pause);
      }
      expect(moves, const [
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 60),
        Duration(seconds: 60),
        Duration(seconds: 60),
      ]);

      async.elapse(remoteSeekSeriesWindow);
      expect(series.press(forward: false), const Duration(seconds: -10));
      async.elapse(pause);
      expect(series.press(forward: false), const Duration(seconds: -30));
      async.elapse(pause);
      expect(series.press(forward: false), const Duration(seconds: -60));
      series.dispose();
    });
  });

  test('back to 10 s after 1.5 s without a press, not before', () {
    fakeAsync((async) {
      final series = RemoteSeekSeries();
      series.press(forward: true);
      async.elapse(remoteSeekSeriesWindow - const Duration(milliseconds: 1));
      expect(series.press(forward: true), const Duration(seconds: 30), reason: '1.499 s after the first press');
      async.elapse(remoteSeekSeriesWindow - const Duration(milliseconds: 1));
      expect(series.press(forward: true), const Duration(seconds: 60), reason: 'the window counts from the last press');

      async.elapse(remoteSeekSeriesWindow);
      expect(series.press(forward: true), const Duration(seconds: 10), reason: '1.5 s after the last press');
      series.dispose();
    });
  });

  test('the other way starts a new series at 10 s', () {
    fakeAsync((async) {
      final series = RemoteSeekSeries();
      series.press(forward: true);
      series.press(forward: true);
      expect(series.press(forward: false), const Duration(seconds: -10));
      expect(series.press(forward: false), const Duration(seconds: -30));
      expect(series.press(forward: true), const Duration(seconds: 10));
      series.dispose();
    });
  });

  test('the hint shows the way and the step of the last press, and goes with the series', () {
    fakeAsync((async) {
      final series = RemoteSeekSeries();
      var notified = 0;
      series.addListener(() => notified++);
      expect(series.hint, isNull);

      series.press(forward: true);
      expect(series.hint, (forward: true, step: const Duration(seconds: 10)));
      async.elapse(pause);
      series.press(forward: true);
      expect(series.hint, (forward: true, step: const Duration(seconds: 30)));
      series.press(forward: false);
      expect(series.hint, (forward: false, step: const Duration(seconds: 10)));
      expect(notified, 3);

      async.elapse(remoteSeekSeriesWindow - const Duration(milliseconds: 1));
      expect(series.hint, isNotNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(series.hint, isNull);
      expect(notified, 4);
      series.dispose();
    });
  });

  test('end() closes the series at once: the next press moves 10 s', () {
    fakeAsync((async) {
      final series = RemoteSeekSeries();
      series.press(forward: true);
      series.press(forward: true);
      series.end();
      expect(series.hint, isNull);
      expect(series.press(forward: true), const Duration(seconds: 10));
      series.end();
      series.end();
      async.elapse(remoteSeekSeriesWindow * 2);
      expect(series.hint, isNull);
      series.dispose();
    });
  });

  test('disposed during a series, its timer goes with it', () {
    fakeAsync((async) {
      final series = RemoteSeekSeries();
      series.press(forward: true);
      series.dispose();
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('the series of a player lives while it runs, whoever reads it, then goes', () {
    fakeAsync((async) {
      final container = ProviderContainer();
      final first = container.read(remoteSeekSeriesProvider('video'));
      first.press(forward: true);
      async.elapse(pause);
      final again = container.read(remoteSeekSeriesProvider('video'));
      expect(again, same(first), reason: 'nobody watches it, but its series runs');
      expect(again.press(forward: true), const Duration(seconds: 30));
      expect(container.read(remoteSeekSeriesProvider('other')), isNot(same(first)), reason: 'one per player');

      async.elapse(remoteSeekSeriesWindow * 2);
      final later = container.read(remoteSeekSeriesProvider('video'));
      expect(later, isNot(same(first)), reason: 'the series over and nobody watching, it went');
      expect(later.press(forward: true), const Duration(seconds: 10));
      container.dispose();
      async.flushTimers();
    });
  });

  testWidgets('the hint, in the words of the language of the app', (tester) async {
    final series = RemoteSeekSeries();
    addTearDown(series.dispose);
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: const Locale('ja'),
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: VideoSeekHint(series: series)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video_seek_hint')), findsNothing, reason: 'nothing between series');

    series.press(forward: false);
    series.press(forward: false);
    await tester.pump();
    expect(find.text('30 秒'), findsOneWidget);
    expect(find.byIcon(Icons.fast_rewind_rounded), findsOneWidget);

    await tester.pump(remoteSeekSeriesWindow);
    expect(find.byKey(const Key('video_seek_hint')), findsNothing);
  });
}
