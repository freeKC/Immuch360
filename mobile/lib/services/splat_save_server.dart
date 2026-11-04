// The Immich server a SplatSaveJob saves to (plan of 3 November 2026, section 6.3), through the app's API client, its
// upload service and its shared HTTP client: the version, an asset, the search by original file name, the head of an
// original (one range request, without the edited parameter), bulk-upload-check, the upload and the album.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
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
  }) : _headers = headers ?? ApiService.getRequestHeaders;

  /// The server's endpoint, "https://photos.example/api"
  @override
  final String url;
  final ApiService _api;
  final ForegroundUploadService _uploads;
  final http.Client? _client;
  final Map<String, String> Function() _headers;

  http.Client get _http => _client ?? NetworkRepository.client;

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
      final asset = await _api.assetsApi.getAssetInfo(id);
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
    final found = await _api.searchApi.searchAssets(
      MetadataSearchDto(
        originalFileName: Optional.present(name),
        size: Optional.present(size),
        withDeleted: const Optional.present(true),
        order: const Optional.present(AssetOrder.desc),
      ),
    );
    return [for (final asset in found?.assets.items ?? const <AssetResponseDto>[]) _of(asset)];
  }

  @override
  Future<Uint8List?> head(String assetId, int length) async {
    try {
      final request = http.Request('GET', splatPhotoOriginalUri(url, assetId))
        ..headers.addAll(_headers())
        ..headers['range'] = 'bytes=0-${length - 1}';
      final response = await _http.send(request);
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.drain<void>();
        return null;
      }
      // A 200 sends the whole file: only its first bytes are read, then the answer is dropped
      final builder = BytesBuilder(copy: false);
      final done = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen(
        (chunk) {
          builder.add(chunk);
          if (builder.length >= length && !done.isCompleted) {
            done.complete();
            unawaited(subscription.cancel());
          }
        },
        onError: (Object error) => done.isCompleted ? null : done.completeError(error),
        onDone: () => done.isCompleted ? null : done.complete(),
        cancelOnError: true,
      );
      await done.future;
      final bytes = builder.takeBytes();
      return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<SplatBulkAnswer> bulkCheck(String id, String sha1) async {
    final answer = await _api.assetsApi.checkBulkUpload(
      AssetBulkUploadCheckDto(
        assets: [AssetBulkUploadCheckItem(id: id, checksum: sha1)],
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
      return await _api.albumsApi.getAlbumInfo(id) != null;
    } on ApiException catch (error) {
      if (error.code == HttpStatus.notFound || error.code == HttpStatus.badRequest) {
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<String> createAlbum(String name) async {
    final album = await _api.albumsApi.createAlbum(CreateAlbumDto(albumName: name));
    if (album == null) {
      throw StateError('the server made no album');
    }
    return album.id;
  }

  @override
  Future<void> addToAlbum(String albumId, String assetId) async {
    await _api.albumsApi.addAssetsToAlbum(albumId, BulkIdsDto(ids: [assetId]));
  }
}
