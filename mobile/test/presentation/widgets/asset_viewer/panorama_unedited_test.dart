// The 360° views never show an edited picture: a photo turned with the one-key rotation (or edited in the editor)
// while it was viewed flat, then viewed as 360°, comes to the sphere and to the immersive viewer of the Meta Quest as
// the camera made it. Those views turn their camera, and follow the head or the phone by themselves.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../../widget_tester_extensions.dart';

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  const _TestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) => Future.value(this);

  @override
  ImageStreamCompleter loadImage(_TestImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image.clone())));
}

void main() {
  late PresentationContext context;
  const server = PresentationContext.serverEndpoint;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  // Turned on the server while viewed flat, then chosen to be viewed as 360°
  final edited = RemoteAssetFactory.create(width: 4096, height: 2048, name: 'trip.jpg').copyWith(isEdited: true);

  test('the sphere loads the unedited thumbnail, preview and original', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = container.read(panoramaImageProvider)(edited, const Size(1080, 1920));
    expect(provider, isA<RemoteFullImageProvider>());
    expect((provider as RemoteFullImageProvider).edited, isFalse);
  });

  test('the immersive viewer of a Meta Quest opens the unedited original of a photo', () {
    expect(immersiveMediaUrl(edited), '$server/assets/${edited.id}/original?edited=false');
  });

  testWidgets('the sphere reads its GPano tags from the unedited preview', (tester) async {
    final image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    final requests = <Uri>[];
    await tester.pumpConsumerWidget(
      PanoramaViewerPage(asset: edited),
      overrides: [
        panoramaImageProvider.overrideWithValue((_, _) => _TestImageProvider(image)),
        panoramaGPanoClientProvider.overrideWithValue(
          MockClient((request) async {
            requests.add(request.url);
            return http.Response.bytes(const [], 206);
          }),
        ),
        isHorizonOsProvider.overrideWith((ref) => false),
      ],
    );
    await tester.pumpAndSettle();

    expect(requests, [Uri.parse('$server/assets/${edited.id}/thumbnail?size=preview&edited=false')]);
  });

  test('a video of the server opens as it is: the server edits no video', () {
    final video = RemoteAssetFactory.create(type: AssetType.video);
    expect(immersiveMediaUrl(video), '$server/assets/${video.id}/original');
  });
}
