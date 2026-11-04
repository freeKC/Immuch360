// The Immich adapter of the save job (plan of 3 November 2026, section 6.3): the API client gives a failure of the
// network the code 400 of a refusal, so the adapter tells them apart. An unreachable server is never "the asset is
// gone" (which would send the job on to draw and write a poster for nothing) nor "the album is gone" (which would make
// a second album at the next save). The head of a splat photo is read with one range request whose transfer stops once
// its bytes came, after its time, or on a cancel, also with the client of Android, which only stops on an abort.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/services/splat_save_server.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../service.mocks.dart';

class _MockAssetsApi extends Mock implements AssetsApi {}

class _MockAlbumsApi extends Mock implements AlbumsApi {}

class _MockSearchApi extends Mock implements SearchApi {}

/// A server that ignores the range (HTTP 200, a whole original of 60 MiB) behind a client that behaves as package:ok_http
/// does on Android: the body goes on coming whoever listens, until the request is aborted. With [stallAfter], the body
/// stops coming after that many bytes, as a link that hangs, until the abort.
class _AbortOnlyClient extends http.BaseClient {
  _AbortOnlyClient({this.stallAfter});

  final int? stallAfter;
  var produced = 0;
  var aborted = false;
  String? range;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    range = request.headers['range'];
    final controller = StreamController<List<int>>();
    final abort = switch (request) {
      http.Abortable(:final abortTrigger) => abortTrigger,
      _ => null,
    };
    unawaited(
      abort?.whenComplete(() {
        aborted = true;
        if (!controller.isClosed) {
          controller.addError(http.RequestAbortedException(request.url));
          unawaited(controller.close());
        }
      }),
    );
    const total = 60 << 20;
    const piece = 64 << 10;
    unawaited(() async {
      while (produced < total && !aborted) {
        await Future<void>.delayed(Duration.zero);
        final stall = stallAfter;
        if (stall != null && produced >= stall) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        produced += piece;
        if (!controller.isClosed) {
          controller.add(Uint8List(piece));
        }
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    }());
    return http.StreamedResponse(controller.stream, 200, contentLength: total);
  }
}

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

  ImmichSplatSaveServer serverWith(http.Client client, {Duration headTimeout = const Duration(seconds: 15)}) =>
      ImmichSplatSaveServer(
        url: 'http://photos.test/api',
        api: api,
        uploads: MockForegroundUploadService(),
        client: client,
        headers: () => const {},
        headTimeout: headTimeout,
      );

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

  test('the head of a server that ignores the range: its bytes, then the transfer stops', () async {
    final client = _AbortOnlyClient();
    final head = await serverWith(client).head('asset', splatPhotoHeadBytes);
    expect(head, hasLength(splatPhotoHeadBytes));
    expect(client.range, 'bytes=0-${splatPhotoHeadBytes - 1}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(client.aborted, isTrue, reason: 'the client of Android reads on to the end of the original otherwise');
    expect(client.produced, lessThan(1 << 20), reason: '${client.produced} bytes of 60 MiB');
  });

  test('a head read that hangs gives null after its time, and its transfer stops', () async {
    final client = _AbortOnlyClient(stallAfter: 64 << 10);
    final watch = Stopwatch()..start();
    final head = await serverWith(client, headTimeout: const Duration(milliseconds: 300)).head('asset', 128 << 10);
    expect(head, isNull);
    expect(watch.elapsedMilliseconds, lessThan(2000));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(client.aborted, isTrue);
  });

  test('a cancel stops a head read at once', () async {
    final client = _AbortOnlyClient(stallAfter: 64 << 10);
    var cancelled = false;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 100), () => cancelled = true));
    final watch = Stopwatch()..start();
    final head = await serverWith(client).head('asset', 128 << 10, cancelled: () => cancelled);
    expect(head, isNull);
    expect(watch.elapsedMilliseconds, lessThan(2000), reason: 'not the 15 s of the time limit');
    expect(client.aborted, isTrue);
  });
}
