// The size of the file of a photo, upright, before the edits of the server: what the 360° views and the rules that
// tell a photo may be 360° read, never the size an edit gave the asset.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/unedited_frame.dart';

import '../../unit/factories/local_asset_factory.dart';
import '../../unit/factories/remote_asset_factory.dart';

void main() {
  test('an asset without edits has the size of its file', () {
    final photo = RemoteAssetFactory.create(width: 4096, height: 2048);
    expect(uneditedFrameOf(photo, const ExifInfo(width: 1, height: 1)), (width: 4096, height: 2048));
  });

  test('an asset turned on the server has the size the exif read in its file', () {
    final turned = RemoteAssetFactory.create(width: 2048, height: 4096).copyWith(isEdited: true);
    expect(uneditedFrameOf(turned, const ExifInfo(width: 4096, height: 2048)), (width: 4096, height: 2048));
  });

  test('swapped when the exif orientation turns the file a quarter, as the server sizes it', () {
    final turned = RemoteAssetFactory.create(width: 2048, height: 4096).copyWith(isEdited: true);
    const sideways = ExifInfo(width: 2048, height: 4096, isFlipped: true);
    expect(uneditedFrameOf(turned, sideways), (width: 4096, height: 2048));
  });

  test('not known for an edited asset whose exif holds no size', () {
    final turned = RemoteAssetFactory.create(width: 2048, height: 4096).copyWith(isEdited: true);
    final frame = uneditedFrameOf(turned, null);
    expect(frame, (width: null, height: null));
    expect(isKnownFrame(frame), isFalse);
    expect(isKnownFrame(uneditedFrameOf(turned, const ExifInfo(width: 4096, height: 0))), isFalse);
  });

  test('a file of the device is read as it is', () {
    final local = LocalAssetFactory.create(remoteId: 'remote-1');
    expect(hasEditedFrame(local), isFalse);
    expect(uneditedFrameOf(local, const ExifInfo(width: 1, height: 1)), (width: local.width, height: local.height));
  });
}
