// The Immich adapter of the save job (plan of 3 November 2026, section 6.3): the API client gives a failure of the
// network the code 400 of a refusal, so the adapter tells them apart. An unreachable server is never "the asset is
// gone" (which would send the job on to draw and write a poster for nothing) nor "the album is gone" (which would make
// a second album at the next save).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/splat_save_server.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../service.mocks.dart';

class _MockAssetsApi extends Mock implements AssetsApi {}

class _MockAlbumsApi extends Mock implements AlbumsApi {}

class _MockSearchApi extends Mock implements SearchApi {}

void main() {
  late MockApiService api;
  late _MockAssetsApi assets;
  late _MockAlbumsApi albums;
  late _MockSearchApi search;
  late ImmichSplatSaveServer server;

  setUpAll(() {
    registerFallbackValue(MetadataSearchDto());
    registerFallbackValue(AssetBulkUploadCheckDto(assets: const []));
  });

  setUp(() {
    api = MockApiService();
    assets = _MockAssetsApi();
    albums = _MockAlbumsApi();
    search = _MockSearchApi();
    when(() => api.assetsApi).thenReturn(assets);
    when(() => api.albumsApi).thenReturn(albums);
    when(() => api.searchApi).thenReturn(search);
    server = ImmichSplatSaveServer(
      url: 'http://photos.test/api',
      api: api,
      uploads: MockForegroundUploadService(),
      headers: () => const {},
    );
  });

  ApiException network(Exception inner) => ApiException.withInner(400, 'Socket operation failed', inner, null);

  test('an asset the server does not have is null, an unreachable server is a SocketException', () async {
    when(() => assets.getAssetInfo('gone')).thenThrow(ApiException(400, 'Invalid id'));
    when(() => assets.getAssetInfo('missing')).thenThrow(ApiException(404, 'Not found'));
    when(() => assets.getAssetInfo('away')).thenThrow(network(const SocketException('Connection refused')));
    when(() => assets.getAssetInfo('cut')).thenThrow(network(http.ClientException('Connection closed')));

    expect(await server.asset('gone'), isNull);
    expect(await server.asset('missing'), isNull);
    await expectLater(server.asset('away'), throwsA(isA<SocketException>()));
    await expectLater(server.asset('cut'), throwsA(isA<SocketException>()));
  });

  test('an album the server does not have is false, an unreachable server is a SocketException', () async {
    when(() => albums.getAlbumInfo('gone')).thenThrow(ApiException(404, 'Not found'));
    when(() => albums.getAlbumInfo('away')).thenThrow(network(const SocketException('Network is unreachable')));

    expect(await server.albumExists('gone'), isFalse);
    await expectLater(server.albumExists('away'), throwsA(isA<SocketException>()));
  });

  test(
    'the search and bulk-upload-check: an unreachable server is a SocketException, a refusal stays itself',
    () async {
      when(() => search.searchAssets(any())).thenThrow(network(const SocketException('Connection timed out')));
      when(() => assets.checkBulkUpload(any())).thenThrow(ApiException(500, 'Internal server error'));

      await expectLater(server.searchByName('_splat'), throwsA(isA<SocketException>()));
      await expectLater(
        server.bulkCheck('splat-1', 'sha1'),
        throwsA(isA<ApiException>().having((error) => error.code, 'code', 500)),
      );
    },
  );
}
