import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';

import '../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../test_utils/heif_builder.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  late List<String> serverReads;
  late ProviderContainer container;

  setUp(() {
    serverReads = [];
    final file = RecordingReader(jpegFile(width: 8000, height: 3000, xmp: ourXmp()));
    container = ProviderContainer(
      overrides: [
        flatStereoServiceProvider.overrideWithValue(
          FlatStereoService(
            localFile: (_) async => null,
            serverReader: (remoteId) => (offset, length) {
              serverReads.add(remoteId);
              return file.call(offset, length);
            },
          ),
        ),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('an ordinary photo is flat, without a read', () async {
    final asset = RemoteAssetFactory.create(name: 'IMG_0001.jpg', width: 4000, height: 3000);

    expect(await container.read(flatStereoProvider(asset).future), isNull);
    expect(serverReads, isEmpty);
  });

  test('a candidate is read, and what its head says comes out', () async {
    final asset = RemoteAssetFactory.create(name: 'salon_3D_LRF_Full_SBS.jpg', width: 8000, height: 3000);

    final found = await container.read(flatStereoProvider(asset).future);
    expect(found?.isOurs, isTrue);
    expect(found?.eyes, StereoEyes.full);
    expect(serverReads, [asset.id]);
  });
}
