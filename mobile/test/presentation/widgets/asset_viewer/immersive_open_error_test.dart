import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tiff_decoder.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_open_error.dart';

void main() {
  final t = StaticTranslations.instance;

  test('a headset too old for the Spatial SDK is asked to update', () {
    final error = PlatformException(code: kImmersiveHorizonOsTooOld, message: 'API 32');
    expect(immersiveOpenFailedMessage(t, error), t.immersive_viewer_update_headset);
    expect(t.immersive_viewer_update_headset, isNot(t.immersive_viewer_open_failed));
  });

  test('a TIFF that does not decode says so', () {
    expect(immersiveOpenFailedMessage(t, const TiffDecodeException('bad strip')), t.tiff_cannot_decode);
  });

  test('any other failure keeps the plain message', () {
    expect(immersiveOpenFailedMessage(t, PlatformException(code: 'unsupported')), t.immersive_viewer_open_failed);
    expect(immersiveOpenFailedMessage(t, StateError('gone')), t.immersive_viewer_open_failed);
  });
}
