// The Immich server a SplatSaveJob saves to (plan of 3 November 2026, section 6.3), through the app's API client, its
// upload service and its shared HTTP client: the version, an asset, the search by original file name, the head of an
// original (one range request, without the edited parameter), bulk-upload-check, the upload and the album.
//
// The head is read by httpRangeReader, whose transfer stops by an abort once the bytes came, past the time limit or on
// a cancel: the client of Android (package:ok_http) reads on to the end of a body nobody listens to, and a server that
// ignores the range, as FreeKC's does, would send each whole splat photo read (review of 4 November 2026).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:openapi/api.dart';

class ImmichSplatSaveServer implements SplatSaveServer {
  ImmichSplatSaveServer({
    required this.url,
    required this._api,
    required this._uploads,
    this._client,
    Map<String, String> Function()? headers,
    this.headTimeout = const Duration(seconds: 15),
  }) : _headers = headers ?? ApiService.getRequestHeaders;

  /// The server's endpoint, "https://photos.example/api"
  @override
  final String url;
  final ApiService _api;
  final ForegroundUploadService _uploads;
  final http.Client? _client;
  final Map<String, String> Function() _headers;

  /// The longest a head read takes, as the probe of the splat photos gives its own
  final Duration headTimeout;

  http.Client get _http => _client ?? NetworkRepository.client;

  /// A call of the API client, a failure of the network thrown as the SocketException the job reads as
  /// "unreachable": the client gives it the code 400 of a refusal, told apart by its inner exception, so that an
  /// unreachable server is never "the asset is gone" nor "the album is gone"
  Future<T> _reach<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (error) {
      final inner = error.innerException;
      if (inner is SocketException) {
        throw inner;
      }
      if (inner is IOException || inner is http.ClientException) {
        throw SocketException('$inner');
      }
      rethrow;
    }
  }

  @override
  Future<(int, int, int)?> version() async {
    try {
      final version = await _api.serverInfoApi.getServerVersion();
      return version == null ? null : (version.major, version.minor, version.patch_);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<SplatServerAsset?> asset(String id) async {
    try {
      final asset = await _reach(() => _api.assetsApi.getAssetInfo(id));
      return asset == null ? null : _of(asset);
    } on ApiException catch (error) {
      if (error.code == HttpStatus.notFound || error.code == HttpStatus.badRequest) {
        return null;
      }
      rethrow;
    }
  }

  SplatServerAsset _of(AssetResponseDto asset) => SplatServerAsset(
    id: asset.id,
    originalFileName: asset.originalFileName,
    isTrashed: asset.isTrashed,
    // When it reached the server: "saved on {date}"
    createdAt: asset.createdAt,
  );

  @override
  Future<List<SplatServerAsset>> searchByName(String name, {int size = 50}) async {
    final found = await _reach(
      () => _api.searchApi.searchAssets(
        MetadataSearchDto(
          originalFileName: Optional.present(name),
          size: Optional.present(size),
          withDeleted: const Optional.present(true),
          order: const Optional.present(AssetOrder.desc),
        ),
      ),
    );
    return [for (final asset in found?.assets.items ?? const <AssetResponseDto>[]) _of(asset)];
  }

  @override
  Future<Uint8List?> head(String assetId, int length, {bool Function()? cancelled}) async {
    // Past its time the read is dropped, and its transfer stopped as on a cancel
    var over = false;
    final read = httpRangeReader(
      _http,
      splatPhotoOriginalUri(url, assetId),
      headers: _headers(),
      cancelled: () => over || (cancelled?.call() ?? false),
    );
    try {
      return await read(0, length).timeout(headTimeout);
    } catch (_) {
      return null;
    } finally {
      over = true;
    }
  }

  @override
  Future<SplatBulkAnswer> bulkCheck(String id, String sha1) async {
    final answer = await _reach(
      () => _api.assetsApi.checkBulkUpload(
        AssetBulkUploadCheckDto(
          assets: [AssetBulkUploadCheckItem(id: id, checksum: sha1)],
        ),
      ),
    );
    final result = answer?.results.where((result) => result.id == id).firstOrNull;
    if (result == null || result.action == AssetUploadAction.accept) {
      return const SplatBulkAnswer(accept: true);
    }
    return SplatBulkAnswer(
      accept: false,
      assetId: result.assetId.isPresent ? result.assetId.value : null,
      isTrashed: result.isTrashed.isPresent && result.isTrashed.value == true,
    );
  }

  @override
  Future<UploadResult> upload(UploadSource source, {Completer<void>? cancel, void Function(int, int)? onProgress}) =>
      _uploads.uploadSource(source, cancelToken: cancel, onProgress: onProgress);

  @override
  Future<bool> albumExists(String id) async {
    try {
      return await _reach(() => _api.albumsApi.getAlbumInfo(id)) != null;
    } on ApiException catch (error) {
      if (error.code == HttpStatus.notFound || error.code == HttpStatus.badRequest) {
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<String> createAlbum(String name) async {
    final album = await _reach(() => _api.albumsApi.createAlbum(CreateAlbumDto(albumName: name)));
    if (album == null) {
      throw StateError('the server made no album');
    }
    return album.id;
  }

  @override
  Future<void> addToAlbum(String albumId, String assetId) async {
    await _reach(() => _api.albumsApi.addAssetsToAlbum(albumId, BulkIdsDto(ids: [assetId])));
  }
}
