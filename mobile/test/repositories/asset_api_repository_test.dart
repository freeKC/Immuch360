import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _MockAssetsApi extends Mock implements AssetsApi {}

class _MockStacksApi extends Mock implements StacksApi {}

class _MockTrashApi extends Mock implements TrashApi {}

class _MockAsset extends Mock implements AssetResponseDto {}

void main() {
  late _MockAssetsApi api;
  late AssetApiRepository sut;

  setUp(() {
    api = _MockAssetsApi();
    sut = AssetApiRepository(api, _MockStacksApi(), _MockTrashApi());
  });

  void answer(String id, Future<AssetResponseDto?> Function() response) =>
      when(() => api.getAssetInfo(id)).thenAnswer((_) => response());

  AssetResponseDto asset({required bool isTrashed}) {
    final asset = _MockAsset();
    when(() => asset.isTrashed).thenReturn(isTrashed);
    return asset;
  }

  group('presence', () {
    test('tells an asset in the library from one in the trash', () async {
      answer('kept', () async => asset(isTrashed: false));
      answer('trashed', () async => asset(isTrashed: true));

      expect(await sut.presence('kept'), RemoteAssetPresence.inLibrary);
      // The server answers "duplicate" to a new upload of a trashed file and leaves it in the trash
      expect(await sut.presence('trashed'), RemoteAssetPresence.inTrash);
    });

    test('is gone for an asset the server does not have', () async {
      answer('deleted', () => throw ApiException(400, 'Not found or no asset.read access'));
      answer('gone', () => throw ApiException(404, 'Not found'));

      expect(await sut.presence('deleted'), RemoteAssetPresence.gone);
      expect(await sut.presence('gone'), RemoteAssetPresence.gone);
    });

    test('throws when the server cannot tell', () async {
      answer('any', () => throw ApiException(500, 'Internal server error'));

      await expectLater(sut.presence('any'), throwsA(isA<ApiException>()));
    });
  });
}
