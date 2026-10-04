import 'package:flutter_test/flutter_test.dart';
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

  group('isInLibrary', () {
    test('is true for an asset the server has, in or out of the trash', () async {
      answer('kept', () async => asset(isTrashed: false));
      answer('trashed', () async => asset(isTrashed: true));

      expect(await sut.isInLibrary('kept'), isTrue);
      // The server answers "duplicate" to a new upload of a trashed file and leaves it in the trash
      expect(await sut.isInLibrary('trashed'), isTrue);
    });

    test('is false for an asset the server does not have', () async {
      answer('deleted', () => throw ApiException(400, 'Not found or no asset.read access'));
      answer('gone', () => throw ApiException(404, 'Not found'));

      expect(await sut.isInLibrary('deleted'), isFalse);
      expect(await sut.isInLibrary('gone'), isFalse);
    });

    test('throws when the server cannot tell', () async {
      answer('any', () => throw ApiException(500, 'Internal server error'));

      await expectLater(sut.isInLibrary('any'), throwsA(isA<ApiException>()));
    });
  });
}
