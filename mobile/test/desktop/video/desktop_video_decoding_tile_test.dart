// "Video decoding" in the details of a video on the computers (desktop_video_decoding_tile.dart): the decoder and the
// card of the video playing, with the English texts, on the machines of video_gpu_test.dart: the development laptop
// with the app on the RTX 4060 (the runner's export) or on the Intel UHD (Windows set to power saving for it), and a
// computer whose cards are not known (Linux, macOS). While the server's copy of a video plays because its original is
// beyond this computer, the advice is about the original.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/desktop_video_decoding_tile.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/video_gpu.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';

import '../../unit/factories/remote_asset_factory.dart';

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
const _copy = (width: 1280, height: 720);

const _advice =
    'NVIDIA GeForce RTX 4060 Laptop GPU plays 4K and 8K videos more smoothly: choose High performance for Immuch360 '
    'in Windows Settings, System, Display, Graphics, then restart Immuch360';

/// What the player chose for an 8K HEVC server video whose original the decoder check found beyond this computer
const _switched = ChosenVideoSource(
  url: 'playback',
  kind: VideoSourceKind.transcoded,
  notice: VideoSourceNotice(.switched, codec: 'HEVC', width: 7680, height: 4320),
  hasCopy: true,
);

void main() {
  late ValueNotifier<VideoDecoding> decoding;
  late ProviderContainer container;

  setUp(() {
    decoding = ValueNotifier((hwdec: null, size: null));
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  Future<void> pumpTile(WidgetTester tester, VideoMachine machine, {bool given = true, BaseAsset? asset}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: EasyLocalization(
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
                    DesktopVideoDecodingTile(
                      asset: asset,
                      decoding: given ? decoding : null,
                      machine: () async => machine,
                    ),
                  ],
                ),
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

  testWidgets("the server's copy plays because the 8K original is beyond the Intel: the advice is about the original", (
    tester,
  ) async {
    final video = RemoteAssetFactory.create(type: .video);
    container.read(chosenVideoSourcesProvider.notifier).record(video.id, _switched);
    decoding.value = (hwdec: 'd3d11va', size: _copy);
    await pumpTile(tester, (inUse: _intel, gpus: _laptop), asset: video);
    expect(subtitle(tester), 'Hardware, on Intel(R) UHD Graphics  •  d3d11va\n$_advice');
    // On the RTX the original plays: nothing to say, whatever the player chose (a new tile: it reads the cards once)
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpTile(tester, (inUse: _rtx, gpus: _laptop), asset: video);
    expect(subtitle(tester), 'Hardware, on NVIDIA GeForce RTX 4060 Laptop GPU  •  d3d11va');
  });

  testWidgets("the server's copy chosen by the settings or by the user, or the original playing: the stream decides", (
    tester,
  ) async {
    final video = RemoteAssetFactory.create(type: .video);
    final sources = container.read(chosenVideoSourcesProvider.notifier);
    decoding.value = (hwdec: 'd3d11va', size: _copy);
    // "Always the transcoded stream": High performance would not play the original
    sources.record(video.id, const ChosenVideoSource(url: 'playback', kind: VideoSourceKind.transcoded, hasCopy: true));
    await pumpTile(tester, (inUse: _intel, gpus: _laptop), asset: video);
    expect(subtitle(tester), 'Hardware, on Intel(R) UHD Graphics  •  d3d11va');
    // The copy forced in the details
    sources.record(
      video.id,
      const ChosenVideoSource(
        url: 'playback',
        kind: VideoSourceKind.transcoded,
        notice: VideoSourceNotice(.copyForced, codec: 'HEVC', width: 1280, height: 720),
        hasCopy: true,
      ),
    );
    await tester.pump();
    expect(subtitle(tester), 'Hardware, on Intel(R) UHD Graphics  •  d3d11va');
    // The original forced although beyond the decoders: the 8K stream itself tells
    sources.record(
      video.id,
      const ChosenVideoSource(
        url: 'original',
        notice: VideoSourceNotice(.originalForced, codec: 'HEVC', width: 7680, height: 4320),
        hasCopy: true,
      ),
    );
    decoding.value = (hwdec: 'd3d11va', size: _eightK);
    await tester.pump();
    expect(subtitle(tester), 'Hardware, on Intel(R) UHD Graphics  •  d3d11va\n$_advice');
    // Another video's choice says nothing about this one
    final other = RemoteAssetFactory.create(type: .video);
    sources.record(other.id, _switched);
    decoding.value = (hwdec: 'd3d11va', size: _copy);
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
