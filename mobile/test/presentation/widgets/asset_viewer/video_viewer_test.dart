import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

/// What the file of every video declares: [result], nothing by default. Records the videos probed.
class _FakeSphericalProbes extends SphericalProbeService {
  _FakeSphericalProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  SphericalProbe? result;
  final probed = <BaseAsset>[];

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async {
    probed.add(asset);
    return result;
  }
}

/// Answers the decoder check with [supported]
class _FakeVideoDecoderApi extends VideoDecoderApi {
  bool supported = true;

  @override
  Future<DecodeVerdict> canDecode(String codec, String? codecs, int width, int height, double frameRate) async =>
      DecodeVerdict(supported: supported, hardware: true, maxWidth: 4096, maxHeight: 4096);
}

void main() {
  late PresentationContext context;
  late MockStorageRepository storage;
  late _FakeSphericalProbes probes;
  late _FakeVideoDecoderApi decoderApi;

  final local = LocalAssetFactory.create(id: 'local-1').copyWith(type: .video, playbackStyle: .video);
  final remote = RemoteAssetFactory.create(type: .video, localId: local.id);

  setUp(() async {
    context = await PresentationContext.create();
    storage = MockStorageRepository();
    probes = _FakeSphericalProbes();
    decoderApi = _FakeVideoDecoderApi();
    final assets = context.service.asset.service;
    when(() => assets.getAsset(remote)).thenAnswer((_) async => remote);
    when(() => assets.getAsset(local)).thenAnswer((_) async => local);
    when(() => assets.getLocalAsset(local.id)).thenAnswer((_) async => local);
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<VideoSource?> pumpViewer(WidgetTester tester, BaseAsset asset, {AppConfig? appConfig}) async {
    await tester.pumpTestWidget(
      context,
      NativeVideoViewer(asset: asset, image: const SizedBox()),
      overrides: [
        storageRepositoryProvider.overrideWithValue(storage),
        sphericalProbeServiceProvider.overrideWithValue(probes),
        // Overridden where the viewer reads it: its scope is below the one of the app
        videoSourceServiceProvider.overrideWithValue(VideoSourceService(decoderApi)),
        if (appConfig != null) appConfigProvider.overrideWithValue(appConfig),
      ],
      expectSettle: false,
    );
    return tester.state<NativeVideoViewerState>(find.byType(NativeVideoViewer)).videoSource;
  }

  testWidgets('plays the local file when it exists', (tester) async {
    final file = File('/videos/local-1.mp4');
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => file);

    final source = await pumpViewer(tester, remote);

    expect(source?.type, VideoSourceType.file);
    expect(source?.path, endsWith(file.path));
  });

  testWidgets('plays the server copy when the local file cannot be read', (tester) async {
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => null);

    final source = await pumpViewer(tester, remote);

    expect(source?.type, VideoSourceType.network);
    expect(source?.path, endsWith('/assets/${remote.id}/video/playback'));
    expect(probes.probed, isEmpty, reason: 'the transcoded stream plays whatever the file');
  });

  group('with the device choosing between the original and the transcoded stream', () {
    final serverOnly = RemoteAssetFactory.create(type: .video);
    const appConfig = AppConfig(viewer: ViewerConfig(videoSource: .preferOriginalWithinDecoder));
    const probe8k = SphericalProbe(codec: 'hvc1', codedWidth: 7680, codedHeight: 3840, frameRate: 30);

    setUp(() {
      when(() => context.service.asset.service.getAsset(serverOnly)).thenAnswer((_) async => serverOnly);
      probes.result = probe8k;
    });

    testWidgets('plays the original the device decodes', (tester) async {
      final source = await pumpViewer(tester, serverOnly, appConfig: appConfig);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
      expect(probes.probed, [serverOnly]);
    });

    testWidgets('plays the transcoded stream when the device cannot decode the original', (tester) async {
      decoderApi.supported = false;

      final source = await pumpViewer(tester, serverOnly, appConfig: appConfig);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/video/playback'));
    });

    testWidgets('plays the original when nothing tells what the file is', (tester) async {
      probes.result = null;

      final source = await pumpViewer(tester, serverOnly, appConfig: appConfig);

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
    });

    testWidgets('plays the original whatever the device when the user asks for it', (tester) async {
      decoderApi.supported = false;

      final source = await pumpViewer(
        tester,
        serverOnly,
        appConfig: const AppConfig(viewer: ViewerConfig(videoSource: .alwaysOriginal)),
      );

      expect(source?.path, endsWith('/assets/${serverOnly.id}/original'));
    });

    testWidgets('plays the original the former switch asked for, within the decoders', (tester) async {
      decoderApi.supported = false;

      final source = await pumpViewer(
        tester,
        serverOnly,
        appConfig: const AppConfig(viewer: ViewerConfig(loadOriginalVideo: true)),
      );

      expect(source?.path, endsWith('/assets/${serverOnly.id}/video/playback'));
    });
  });

  testWidgets('gives up when a local only asset has no file', (tester) async {
    when(() => storage.getFileForAsset(local.id)).thenAnswer((_) async => null);

    final source = await pumpViewer(tester, local);

    expect(source, isNull);
  });
}
