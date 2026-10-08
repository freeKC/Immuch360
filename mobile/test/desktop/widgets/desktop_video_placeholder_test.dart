// Videos on a computer before the desktop player (phase 2): the viewer keeps the poster and says that playback comes
// later, and never builds the native player view, whose plugin has no Windows or Linux side.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/local_asset_factory.dart';
import '../../unit/presentation/presentation_context.dart';

class _NoProbes extends SphericalProbeService {
  _NoProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async => null;
}

class _Decoder extends VideoDecoderApi {
  @override
  Future<DecodeVerdict> canDecode(
    String codec,
    String? codecs,
    int width,
    int height,
    double frameRate,
    int bitDepth,
    int transferCharacteristics, {
    int instances = 1,
  }) async => DecodeVerdict(supported: true, hardware: true, maxWidth: 4096, maxHeight: 4096);
}

void main() {
  late PresentationContext context;
  late MockStorageRepository storage;
  final video = LocalAssetFactory.create(id: 'local-1').copyWith(type: .video, playbackStyle: .video);

  setUp(() async {
    context = await PresentationContext.create();
    storage = MockStorageRepository();
    when(() => context.service.asset.service.getAsset(video)).thenAnswer((_) async => video);
    when(() => storage.getFileForAsset(video.id)).thenAnswer((_) async => File('/videos/local-1.mp4'));
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  for (final platform in const [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('${platform.name}: the poster stays, with the line saying that playback comes later', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpTestWidget(
        context,
        NativeVideoViewer(
          asset: video,
          isCurrent: true,
          image: const SizedBox(key: Key('poster')),
        ),
        overrides: [
          storageRepositoryProvider.overrideWithValue(storage),
          sphericalProbeServiceProvider.overrideWithValue(_NoProbes()),
          videoSourceServiceProvider.overrideWithValue(VideoSourceService(_Decoder())),
        ],
        expectSettle: false,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('poster')), findsOneWidget);
      expect(find.byType(DesktopVideoPlaceholder), findsOneWidget);
      expect(find.text('Video playback comes to Immuch360 Desktop in a later version'), findsOneWidget);
      expect(find.byType(NativeVideoPlayerView), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('the placeholder follows the text size of the system', (tester) async {
    await tester.pumpTestWidget(
      context,
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(2)),
        child: SizedBox(width: 400, height: 300, child: DesktopVideoPlaceholder()),
      ),
    );
    final text = tester.widget<Text>(find.text('Video playback comes to Immuch360 Desktop in a later version'));
    expect(text.textScaler, isNull, reason: 'no fixed scale: the MediaQuery one applies');
    expect(tester.takeException(), isNull, reason: 'no overflow at twice the text size');
  });
}
