import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/desktop_file_media_repository.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';

void main() {
  test('no file behind a local asset and nothing saved before the folder library exists', () async {
    final storage = DesktopStorageRepository();
    expect(await storage.getFileForAsset('f0'), isNull);
    expect(await storage.isAssetAvailableLocally('f0'), isFalse);
    expect(await const DesktopFileMediaRepository().saveImageWithFile('/tmp/none.jpg'), isNull);
  });
}
