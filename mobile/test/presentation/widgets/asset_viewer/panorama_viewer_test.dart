import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../service.mocks.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../widget_tester_extensions.dart';

void main() {
  _rangeTests();
  group('parseGPanoCrop', () {
    test('parses the XMP exiftool writes into previews, in both tag styles', () {
      // Element style, as the server's copyTagGroup produces
      const elements = '''
  <GPano:CroppedAreaImageHeightPixels>1667</GPano:CroppedAreaImageHeightPixels>
  <GPano:CroppedAreaImageWidthPixels>4460</GPano:CroppedAreaImageWidthPixels>
  <GPano:CroppedAreaLeftPixels>0</GPano:CroppedAreaLeftPixels>
  <GPano:CroppedAreaTopPixels>2035</GPano:CroppedAreaTopPixels>
  <GPano:FullPanoHeightPixels>4601</GPano:FullPanoHeightPixels>
  <GPano:FullPanoWidthPixels>9202</GPano:FullPanoWidthPixels>''';
      // Attribute style, as cameras write into originals
      const attributes =
          '<rdf:Description GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="2035" '
          'GPano:CroppedAreaImageWidthPixels="4460" GPano:CroppedAreaImageHeightPixels="1667" '
          'GPano:FullPanoWidthPixels="9202" GPano:FullPanoHeightPixels="4601"/>';
      const expected = Rect.fromLTWH(0, 2035 / 4601, 4460 / 9202, 1667 / 4601);

      expect(parseGPanoCrop(elements), expected);
      expect(parseGPanoCrop(attributes), expected);
      expect(parseGPanoCrop('no GPano tags'), isNull);
    });
  });

  group('parseGPanoInitialView', () {
    test('reads the heading and pitch in both tag styles', () {
      const elements = '''
  <GPano:InitialViewHeadingDegrees>90</GPano:InitialViewHeadingDegrees>
  <GPano:InitialViewPitchDegrees>12.5</GPano:InitialViewPitchDegrees>''';
      const attributes = '<rdf:Description GPano:InitialViewHeadingDegrees="90" GPano:InitialViewPitchDegrees="12.5"/>';
      const expected = (heading: 90.0, pitch: 12.5, poseHeading: 0.0);

      expect(parseGPanoInitialView(elements), expected);
      expect(parseGPanoInitialView(attributes), expected);
      // Single quotes and spaces around the equal sign are valid XML too
      expect(
        parseGPanoInitialView("GPano:InitialViewHeadingDegrees = '90' GPano:InitialViewPitchDegrees='12.5'"),
        expected,
      );
    });

    test('reads negative and decimal values', () {
      const xmp =
          '<GPano:InitialViewHeadingDegrees>-45.25</GPano:InitialViewHeadingDegrees>'
          '<GPano:InitialViewPitchDegrees>-.5</GPano:InitialViewPitchDegrees>'
          '<GPano:PoseHeadingDegrees>+12.75</GPano:PoseHeadingDegrees>';

      expect(parseGPanoInitialView(xmp), (heading: -45.25, pitch: -0.5, poseHeading: 12.75));
    });

    test('reads the pose heading, 0 when missing', () {
      const withPose =
          'GPano:PoseHeadingDegrees="237.5" GPano:InitialViewHeadingDegrees="10" GPano:InitialViewPitchDegrees="0"';

      expect(parseGPanoInitialView(withPose)?.poseHeading, 237.5);
      expect(
        parseGPanoInitialView('GPano:InitialViewHeadingDegrees="10" GPano:InitialViewPitchDegrees="0"')?.poseHeading,
        0,
      );
    });

    test('needs both the heading and the pitch, like the web viewer', () {
      expect(parseGPanoInitialView('GPano:InitialViewHeadingDegrees="90"'), isNull);
      expect(parseGPanoInitialView('<GPano:InitialViewPitchDegrees>10</GPano:InitialViewPitchDegrees>'), isNull);
      expect(parseGPanoInitialView('GPano:InitialViewHeadingDegrees="" GPano:InitialViewPitchDegrees="10"'), isNull);
      expect(parseGPanoInitialView('no GPano tags'), isNull);
    });

    test('does not mistake other tags for the initial view', () {
      const xmp =
          'GPano:InitialViewRollDegrees="5" GPano:InitialHorizontalFOVDegrees="75" '
          'GPano:PosePitchDegrees="3" GPano:PoseHeadingDegrees="20"';

      expect(parseGPanoInitialView(xmp), isNull);
    });
  });

  group('initialViewDirection', () {
    // The viewer's longitude for a column of the full panorama, u in [0, 1], as the sphere painter maps it
    double longitudeOfColumn(double u) => 360 * (u - 0.5);

    ({double longitude, double latitude}) direction(double heading, {double pitch = 0, double poseHeading = 0}) =>
        initialViewDirection((heading: heading, pitch: pitch, poseHeading: poseHeading));

    test('heading 0 looks at the center column of the full panorama', () {
      expect(direction(0).longitude, longitudeOfColumn(0.5));
    });

    test('headings grow clockwise, to the right in the image', () {
      expect(direction(90).longitude, longitudeOfColumn(0.75));
      expect(direction(-90).longitude, longitudeOfColumn(0.25));
      // Wraps around to the same side
      expect(direction(270).longitude, longitudeOfColumn(0.25));
      expect(direction(450).longitude, longitudeOfColumn(0.75));
      expect(direction(-45.5).longitude, closeTo(-45.5, 1e-9));
    });

    test('headings are compass headings, relative to the pose heading of the image center', () {
      expect(direction(237.5, poseHeading: 237.5).longitude, 0);
      expect(direction(10, poseHeading: 350).longitude, closeTo(20, 1e-9));
      expect(direction(350, poseHeading: 10).longitude, closeTo(-20, 1e-9));
    });

    test('pitch is the latitude, positive upwards, clamped to the poles', () {
      expect(direction(0, pitch: 30).latitude, 30);
      expect(direction(0, pitch: -12.5).latitude, -12.5);
      expect(direction(0, pitch: 120).latitude, 90);
      expect(direction(0, pitch: -120).latitude, -90);
    });
  });

  group('isPanoramaProvider', () {
    test('is true for an equirectangular image once its exif has loaded', () async {
      for (final (asset, projectionType, expected) in [
        (RemoteAssetFactory.create(), ProjectionType.equirectangular, true),
        (RemoteAssetFactory.create(), null, false),
        (RemoteAssetFactory.create(), ProjectionType.cubemap, false),
        // Equirectangular videos are ignored, like web
        (RemoteAssetFactory.create(type: .video), ProjectionType.equirectangular, false),
      ]) {
        final container = ProviderContainer(
          overrides: [
            assetExifProvider(asset).overrideWith((ref) => Stream.value(ExifInfo(projectionType: projectionType))),
            forcedPanoramaAssetsProvider.overrideWith(_ForcedPanoramas.new),
          ],
        );
        addTearDown(container.dispose);
        final isPanorama = container.listen(isPanoramaProvider(asset), (_, _) {});

        expect(isPanorama.read(), isFalse, reason: 'false while the exif is loading');
        await container.read(assetExifProvider(asset).future);
        expect(isPanorama.read(), expected, reason: '${asset.type} $projectionType');
      }
    });
  });

  group('PanoramaBadge', () {
    testWidgets('shows the 360° badge only for equirectangular photos', (tester) async {
      for (final (asset, projectionType, expected) in [
        (RemoteAssetFactory.create(), ProjectionType.equirectangular, findsOneWidget),
        (RemoteAssetFactory.create(), null, findsNothing),
        // Equirectangular videos are ignored, like web
        (RemoteAssetFactory.create(type: .video), ProjectionType.equirectangular, findsNothing),
      ]) {
        final assetService = MockAssetService();
        when(
          () => assetService.watchExif(asset),
        ).thenAnswer((_) => Stream.value(ExifInfo(projectionType: projectionType)));

        await tester.pumpConsumerWidget(
          PanoramaBadge(asset: asset),
          overrides: [
            assetServiceProvider.overrideWithValue(assetService),
            forcedPanoramaAssetsProvider.overrideWith(_ForcedPanoramas.new),
          ],
        );

        expect(find.byIcon(Icons.threesixty_rounded), expected);
      }
    });

    testWidgets('shows the 360° badge for a photo the user chose to view as 360°', (tester) async {
      final photo = RemoteAssetFactory.create();
      final video = RemoteAssetFactory.create(type: .video);
      final assetService = MockAssetService();
      for (final asset in [photo, video]) {
        when(() => assetService.watchExif(asset)).thenAnswer((_) => Stream.value(const ExifInfo()));
      }

      for (final (asset, expected) in [(photo, findsOneWidget), (video, findsNothing)]) {
        await tester.pumpConsumerWidget(
          PanoramaBadge(asset: asset),
          overrides: [
            assetServiceProvider.overrideWithValue(assetService),
            forcedPanoramaAssetsProvider.overrideWith(() => _ForcedPanoramas({photo.id, video.id})),
          ],
        );

        expect(find.byIcon(Icons.threesixty_rounded), expected, reason: '${asset.type}');
      }
    });
  });
}

/// The assets of [keys] viewed as 360°, none by default, without the store
class _ForcedPanoramas extends ForcedPanoramaAssets {
  _ForcedPanoramas([this.keys = const {}]);

  final Set<String> keys;

  @override
  Set<String> build() => keys;
}

void _rangeTests() {
  const xmp =
      '<rdf:Description GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="2035" '
      'GPano:CroppedAreaImageWidthPixels="4460" GPano:CroppedAreaImageHeightPixels="1667" '
      'GPano:FullPanoWidthPixels="9202" GPano:FullPanoHeightPixels="4601"/>';
  const expected = Rect.fromLTWH(0, 2035 / 4601, 4460 / 9202, 1667 / 4601);
  final url = Uri.parse('https://example.test/preview');

  group('fetchGPano', () {
    test('finds the crop at the head of a JPEG preview with one request', () async {
      final ranges = <String>[];
      final client = MockClient((request) async {
        ranges.add(request.headers['range']!);
        return http.Response.bytes(List.filled(131072, 0x20)..setRange(0, xmp.length, xmp.codeUnits), 206);
      });
      expect((await fetchGPano(client, url))?.crop, expected);
      expect(ranges, ['bytes=0-131071']);
    });

    test('returns the initial view with the crop', () async {
      const both = '$xmp GPano:InitialViewHeadingDegrees="-30" GPano:InitialViewPitchDegrees="10"';
      final client = MockClient((_) async => http.Response.bytes(both.codeUnits, 206));
      final gpano = await fetchGPano(client, url);

      expect(gpano?.crop, expected);
      expect(gpano?.initialView, (heading: -30.0, pitch: 10.0, poseHeading: 0.0));
    });

    test('stops at the head of the file when it finds an initial view on a full sphere', () async {
      const initialView = 'GPano:InitialViewHeadingDegrees="45" GPano:InitialViewPitchDegrees="0"';
      final ranges = <String>[];
      final client = MockClient((request) async {
        ranges.add(request.headers['range']!);
        return http.Response.bytes(
          List.filled(131072, 0x20)..setRange(0, initialView.length, initialView.codeUnits),
          206,
        );
      });
      final gpano = await fetchGPano(client, url);

      expect(gpano?.crop, isNull);
      expect(gpano?.initialView, (heading: 45.0, pitch: 0.0, poseHeading: 0.0));
      expect(ranges, ['bytes=0-131071']);
    });

    test('falls back to the tail of the file for a WebP preview', () async {
      final ranges = <String>[];
      final client = MockClient((request) async {
        final range = request.headers['range']!;
        ranges.add(range);
        final body = range.startsWith('bytes=-') ? xmp.codeUnits : List.filled(131072, 0x20);
        return http.Response.bytes(body, 206);
      });
      expect((await fetchGPano(client, url))?.crop, expected);
      expect(ranges, ['bytes=0-131071', 'bytes=-131072']);
    });

    test('stops after one request when the server sent the whole file', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response.bytes(List.filled(300000, 0x20), 200);
      });
      expect(await fetchGPano(client, url), isNull);
      expect(calls, 1);
    });

    test('takes one request for a small preview without crop tags', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response.bytes(List.filled(40000, 0x20), 206);
      });
      expect(await fetchGPano(client, url), isNull);
      expect(calls, 1);
    });

    test('keeps the full sphere on errors and timeouts', () async {
      expect(await fetchGPano(MockClient((_) async => http.Response('nope', 404)), url), isNull);
      final slow = MockClient((_) => Future.delayed(const Duration(seconds: 2), () => http.Response('', 206)));
      expect(await fetchGPano(slow, url, timeout: const Duration(milliseconds: 50)), isNull);
    });
  });
}
