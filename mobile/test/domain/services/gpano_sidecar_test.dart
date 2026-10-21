import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/gpano_sidecar.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

void main() {
  test('the sidecar is an XMP packet with the GPano tags of the frame, in their namespaces', () {
    final xmp = gpanoSidecarXmp(width: 8192, height: 4096);
    expect(xmp, startsWith('<?xpacket begin="\uFEFF"'));
    expect(xmp.trimRight(), endsWith('<?xpacket end="w"?>'));
    final root = parseLiteXml(xmp);
    final description = root
        .descendantsNamed('Description', namespace: 'http://www.w3.org/1999/02/22-rdf-syntax-ns#')
        .single;
    expect(xmp, contains('xmlns:GPano="http://ns.google.com/photos/1.0/panorama/"'));

    String? tag(String name) => description.attributes[name];
    expect(tag('ProjectionType'), 'equirectangular');
    expect(tag('UsePanoramaViewer'), 'True');
    expect(tag('FullPanoWidthPixels'), '8192');
    expect(tag('FullPanoHeightPixels'), '4096');
    expect(tag('CroppedAreaImageWidthPixels'), '8192');
    expect(tag('CroppedAreaImageHeightPixels'), '4096');
    expect(tag('CroppedAreaLeftPixels'), '0');
    expect(tag('CroppedAreaTopPixels'), '0');
    expect(utf8.encode(xmp).length, lessThan(1200));
  });

  test('the app reads its own sidecar back as a full sphere', () async {
    final bytes = Uint8List.fromList(utf8.encode(gpanoSidecarXmp(width: 5472, height: 2736)));

    final tags = await readGPanoTags(
      (offset, length) async => Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length)),
      bytes.length,
    );

    expect(tags, isNotNull);
    expect(isEquirectangularGPano(tags!), isTrue);
    expect(tags.crop, const Rect.fromLTWH(0, 0, 1, 1));
  });

  test('a frame without a size is refused, and the sidecar is named after the photo', () {
    expect(() => gpanoSidecarXmp(width: 0, height: 4096), throwsArgumentError);
    expect(gpanoSidecarName('DJI_20261021150000_0042_D.JPG'), 'DJI_20261021150000_0042_D.JPG.xmp');
  });
}
