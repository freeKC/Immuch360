// "360° video renderer" in Settings, Advanced (sphere_renderer_tile.dart): Automatic and "not measured yet" at first,
// what the probe kept with the GPU's name and the decoder, a choice saved for the next 360° videos, and Automatic
// picked again forgetting what the probe kept. No "mpv shader" among the choices: DP1 dropped renderer A.

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer_tile.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('sphere_renderer_tile_test');
    SphereRendererStore.forget();
    SphereRendererStore.folder = () async => folder;
  });

  tearDown(() {
    SphereRendererStore.forget();
    folder.deleteSync(recursive: true);
  });

  /// The file is read and written for real, one step at a time: a step lands on a turn of the real event loop and
  /// the next one starts on a frame. Saving a choice takes six steps (exists, open, write, flush, close, rename), and
  /// one slow flush on a loaded machine outlasts any fixed number of rounds: this waits for [text] in the tile
  /// instead, for as long as the disk takes, 10 seconds at most.
  Future<void> settleUntil(WidgetTester tester, String text) async {
    final shown = find.descendant(
      of: find.byKey(const Key('desktop_video_renderer')),
      matching: find.textContaining(text),
    );
    for (var i = 0; i < 500 && shown.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    // The dialog closes on the fake clock
    await tester.pumpAndSettle();
  }

  Future<void> pumpTile(WidgetTester tester, {required String until}) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: const Scaffold(body: SphereRendererTile()),
          ),
        ),
      ),
    );
    await settleUntil(tester, until);
  }

  testWidgets('Automatic, not measured yet; a choice is kept', (tester) async {
    await pumpTile(tester, until: 'Not measured yet');
    expect(find.text('360° video renderer'), findsOneWidget);
    expect(find.textContaining('Automatic'), findsOneWidget);
    expect(find.textContaining('Not measured yet'), findsOneWidget);
    expect(find.textContaining('Settings, System, Display, Graphics'), findsOneWidget);

    await tester.tap(find.byKey(const Key('desktop_video_renderer')));
    await tester.pumpAndSettle();
    expect(find.byType(RadioListTile<SphereRendererChoice>), findsNWidgets(5));
    expect(find.textContaining('mpv'), findsNothing);
    await tester.tap(find.byKey(const Key('desktop_video_renderer_flat')));
    await settleUntil(tester, 'Flat, without the 360° view');
    expect(find.textContaining('Flat, without the 360° view'), findsOneWidget);
    SphereRendererStore.forget();
    final saved = (await tester.runAsync(SphereRendererStore.load))!;
    expect(saved.choice, SphereRendererChoice.flat);
  });

  testWidgets('what the probe kept: the tier, the frames a second, the GPU and the decoder', (tester) async {
    await tester.runAsync(
      () => SphereRendererStore.remember(
        const RememberedRendering(
          appVersion: '3.3.0+21',
          glRenderer: 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)',
          tier: PluginTier.w2880,
          framesPerSecond: 27.3,
          targetFramesPerSecond: 30,
          hwdec: 'd3d11va',
        ),
      ),
    );
    await pumpTile(tester, until: 'Measured last');
    expect(
      find.textContaining(
        'Measured last: Plugin, at most 2880 wide (27.3 / 30 fps) on Intel(R) UHD Graphics, hwdec d3d11va',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Automatic picked again forgets what the probe kept: the next 360° videos are measured again', (
    tester,
  ) async {
    await tester.runAsync(
      () => SphereRendererStore.remember(
        const RememberedRendering(
          appVersion: '3.3.0+21',
          glRenderer: 'ANGLE (Intel, Intel(R) UHD Graphics (0x0000A788) Direct3D11 vs_5_0 ps_5_0, D3D11)',
          tier: null,
          videoClass: 'hevc 7680x3840 30 fps copy',
          framesPerSecond: 11,
          targetFramesPerSecond: 30,
        ),
      ),
    );
    await pumpTile(tester, until: 'Measured last');
    expect(find.textContaining('Measured last: Flat, without the 360° view (11.0 / 30 fps)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('desktop_video_renderer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop_video_renderer_automatic')));
    await settleUntil(tester, 'Not measured yet');
    expect(find.textContaining('Not measured yet'), findsOneWidget);
    SphereRendererStore.forget();
    final saved = (await tester.runAsync(SphereRendererStore.load))!;
    expect(saved.choice, SphereRendererChoice.automatic);
    expect(saved.measured, isEmpty);
  });
}
