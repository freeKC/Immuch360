import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

/// No upload under way
class _IdleUpload extends NetworkUploadNotifier {
  @override
  NetworkUploadState build() => const NetworkUploadState();
}

/// No file of the share sent to the server yet: the records are not read from a store
class _NoRecords extends NetworkUploadRecordsNotifier {
  @override
  Map<String, UploadRecord> build() => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  const pair = HeicStereoPair(
    primaryItemId: 37,
    leftItemId: 37,
    rightItemId: 74,
    pitmIdOffset: 129,
    pitmIdBytes: 2,
    width: 3072,
    height: 3072,
  );
  final spatialBadge = find.byKey(const Key('network_media_spatial_badge'));
  final badge360 = find.byKey(const Key('network_media_360_badge'));

  NetworkEntry entry(String path) =>
      NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: 1000, modified: DateTime.utc(2026, 10, 1));

  /// The tile of [file], whose file declares [info]
  Future<void> pumpTile(WidgetTester tester, NetworkEntry file, NetworkMediaInfo? info) => tester.pumpTestWidget(
    context,
    SizedBox(
      width: 120,
      height: 120,
      child: NetworkMediaTile(entry: file, url: null, onTap: () {}),
    ),
    overrides: [
      networkMediaInfoProvider(networkMediaKey(file)).overrideWith((ref) async => info),
      networkUploadRecordsProvider.overrideWith(_NoRecords.new),
      networkUploadProvider.overrideWith(_IdleUpload.new),
    ],
  );

  testWidgets('a spatial photo gets a 3D badge', (tester) async {
    await pumpTile(tester, entry('/IMG_0001.HEIC'), const NetworkMediaInfo(stereoPair: pair));

    expect(spatialBadge, findsOneWidget);
    expect(find.descendant(of: spatialBadge, matching: find.text('3D')), findsOneWidget);
    expect(badge360, findsNothing);
  });

  testWidgets('a spatial video gets a 3D badge', (tester) async {
    await pumpTile(
      tester,
      entry('/IMG_0002.MOV'),
      const NetworkMediaInfo(
        probe: SphericalProbe(codec: 'hvc1', multiview: MultiviewInfo(heroEye: 1)),
      ),
    );

    expect(spatialBadge, findsOneWidget);
  });

  testWidgets('a flat photo gets none', (tester) async {
    await pumpTile(tester, entry('/IMG_0003.HEIC'), const NetworkMediaInfo());

    expect(spatialBadge, findsNothing);
  });

  testWidgets('a file not read yet gets none', (tester) async {
    await pumpTile(tester, entry('/IMG_0004.HEIC'), null);

    expect(spatialBadge, findsNothing);
  });

  testWidgets('next to the 360° badge when both show', (tester) async {
    await pumpTile(
      tester,
      entry('/both.mov'),
      const NetworkMediaInfo(
        probe: SphericalProbe(hasSphericalMetadata: true, codec: 'hvc1', multiview: MultiviewInfo(heroEye: 1)),
      ),
    );

    expect(spatialBadge, findsOneWidget);
    expect(badge360, findsOneWidget);
    expect(tester.getTopRight(spatialBadge).dx, lessThan(tester.getTopLeft(badge360).dx));
  });
}
