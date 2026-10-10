// The viewer behind the 360° player (design 1.3): on a phone it takes its video back when the app resumes, which
// closing the native player brings about; on a computer the player is a route of the window, resumed comes at every
// focus change even while that route is open, so the viewer takes its video back when the route closes
// (externalPlayerClosedProvider), and never at a focus change.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:mocktail/mocktail.dart';

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

/// Records whether the viewer asked for its video back
class _RecordingPlayer extends VideoPlayerNotifier {
  _RecordingPlayer(this.calls);

  final List<String> calls;

  @override
  Future<void> resumeAfterExternalPlayer() async => calls.add('resume');

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');
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

  Future<void> pumpViewer(WidgetTester tester, List<String> calls) async {
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
        videoPlayerProvider(video.id).overrideWith((ref) => _RecordingPlayer(calls)),
      ],
      expectSettle: false,
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> focusComesBack(WidgetTester tester) async {
    for (final state in const [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
  }

  testWidgets('a computer: a focus change while the 360° route is open gives nothing back, its closing does', (
    tester,
  ) async {
    final calls = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester, calls);

    await focusComesBack(tester);
    expect(calls, isNot(contains('resume')));

    ProviderScope.containerOf(
      tester.element(find.byType(NativeVideoViewer)),
    ).read(externalPlayerClosedProvider.notifier).raise();
    await tester.pump();
    expect(calls, contains('resume'));
    expect(calls, isNot(contains('play')), reason: 'nothing the 360° player left playing to play on');
    await tester.pump(const Duration(seconds: 2));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone: resumed gives the video back, as before', (tester) async {
    final calls = <String>[];
    await pumpViewer(tester, calls);
    await focusComesBack(tester);
    expect(calls, contains('resume'));
    await tester.pump(const Duration(seconds: 2));
  });
}
