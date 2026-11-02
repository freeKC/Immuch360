// "Video decoding" in the details of a video on the computers (desktop_video_decoding_tile.dart): the decoder and the
// card of the video playing, with the English texts, on the machines of video_gpu_test.dart: the development laptop
// with the app on the RTX 4060 (the runner's export) or on the Intel UHD (Windows set to power saving for it), and a
// computer whose cards are not known (Linux, macOS).

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/desktop_video_decoding_tile.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/video_gpu.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

GpuAdapter _gpu(String name, {required int vendor, required bool integrated, required String luid, int mb = 128}) =>
    GpuAdapter(
      index: 0,
      name: name,
      vendorId: vendor,
      deviceId: 1,
      driver: '1.0',
      dedicatedMB: mb,
      sharedMB: 8006,
      integrated: integrated,
      software: false,
      luid: luid,
    );

final _intel = _gpu('Intel(R) UHD Graphics', vendor: 0x8086, integrated: true, luid: '00000000:000164ca');
final _rtx = _gpu(
  'NVIDIA GeForce RTX 4060 Laptop GPU',
  vendor: 0x10DE,
  integrated: false,
  luid: '00000000:0001698d',
  mb: 7956,
);
final _laptop = GpuList(adapters: [_intel, _rtx], highPerformance: _rtx.luid, minimumPower: _intel.luid);

const _eightK = (width: 7680, height: 4320);
const _hd = (width: 1920, height: 1080);

void main() {
  late ValueNotifier<VideoDecoding> decoding;

  setUp(() => decoding = ValueNotifier((hwdec: null, size: null)));

  Future<void> pumpTile(WidgetTester tester, VideoMachine machine, {bool given = true}) async {
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
            home: Scaffold(
              body: Column(
                children: [
                  // EasyLocalization builds its child once the translations are loaded
                  const Text('loaded'),
                  DesktopVideoDecodingTile(decoding: given ? decoding : null, machine: () async => machine),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // The translations load from the generated loader on the real event loop
    for (var i = 0; i < 250 && find.text('loaded').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  String? subtitle(WidgetTester tester) {
    final tile = find.byKey(const Key('desktop_video_decoding'));
    if (tile.evaluate().isEmpty) {
      return null;
    }
    final texts = tester.widgetList<Text>(find.descendant(of: tile, matching: find.byType(Text)));
    return texts.map((text) => text.data).whereType<String>().where((text) => text != 'Video decoding').join('|');
  }

  testWidgets('the app on the RTX (the runner asked the drivers for it): the 8K video decodes there, nothing to do', (
    tester,
  ) async {
    decoding.value = (hwdec: 'd3d11va', size: _eightK);
    await pumpTile(tester, (inUse: _rtx, gpus: _laptop));
    expect(find.text('Video decoding'), findsOneWidget);
    expect(subtitle(tester), 'Hardware, on NVIDIA GeForce RTX 4060 Laptop GPU  •  d3d11va');
  });

  testWidgets('the app on the Intel (Windows set to power saving): the 8K video says where to choose the RTX', (
    tester,
  ) async {
    decoding.value = (hwdec: 'd3d11va', size: _eightK);
    await pumpTile(tester, (inUse: _intel, gpus: _laptop));
    expect(
      subtitle(tester),
      'Hardware, on Intel(R) UHD Graphics  •  d3d11va\n'
      'NVIDIA GeForce RTX 4060 Laptop GPU plays 4K and 8K videos more smoothly: choose High performance for Immuch360 '
      'in Windows Settings, System, Display, Graphics, then restart Immuch360',
    );
    // A 1080p video plays well on the Intel: nothing to suggest
    decoding.value = (hwdec: 'd3d11va', size: _hd);
    await tester.pump();
    expect(subtitle(tester), 'Hardware, on Intel(R) UHD Graphics  •  d3d11va');
  });

  testWidgets('a copy back, the RTX decoding for the Intel, and the processor', (tester) async {
    decoding.value = (hwdec: 'd3d11va-copy', size: _hd);
    await pumpTile(tester, (inUse: _intel, gpus: _laptop));
    expect(subtitle(tester), 'Hardware, on Intel(R) UHD Graphics  •  each frame copied to memory  •  d3d11va-copy');
    decoding.value = (hwdec: 'nvdec-copy', size: _hd);
    await tester.pump();
    expect(
      subtitle(tester),
      'Hardware, on NVIDIA GeForce RTX 4060 Laptop GPU  •  each frame copied to memory  •  nvdec-copy',
    );
    decoding.value = (hwdec: 'no', size: _hd);
    await tester.pump();
    expect(subtitle(tester), 'Software, on the processor');
  });

  testWidgets('nothing until mpv says how it decodes; the card unknown on Linux and macOS', (tester) async {
    await pumpTile(tester, (inUse: null, gpus: null));
    expect(find.byKey(const Key('desktop_video_decoding')), findsNothing);
    decoding.value = (hwdec: 'vaapi', size: _eightK);
    await tester.pump();
    expect(subtitle(tester), 'Hardware, on the graphics card  •  vaapi');
  });

  testWidgets('by default, the video that played last; nothing while none plays', (tester) async {
    expect(activeDesktopVideo.value, isNull);
    await pumpTile(tester, (inUse: _rtx, gpus: _laptop), given: false);
    expect(find.text('loaded'), findsOneWidget);
    expect(find.byKey(const Key('desktop_video_decoding')), findsNothing);
  });
}
