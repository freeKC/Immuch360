// A server in memory for the tests of Save to Immich: the assets it holds by id with their bytes, the calls it got,
// the answers it gives (bulk-upload-check from the SHA-1 of what it holds, uploads stored as new assets).

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';

/// A server in memory: the assets it holds by id, with their bytes; the calls it got
class FakeSplatSaveServer implements SplatSaveServer {
  FakeSplatSaveServer({this.serverVersion = (2, 5, 0)});

  (int, int, int)? serverVersion;
  final assets = <String, ({SplatServerAsset asset, Uint8List bytes})>{};
  final uploads = <({UploadSource source, Uint8List body})>[];
  final calls = <String>[];
  final albums = <String, List<String>>{};
  UploadResult Function(UploadSource source)? answer;
  SplatBulkAnswer? bulkAnswer;
  var next = 0;

  @override
  String get url => 'https://photos.example/api';

  @override
  Future<(int, int, int)?> version() async => serverVersion;

  @override
  Future<SplatServerAsset?> asset(String id) async {
    calls.add('asset $id');
    return assets[id]?.asset;
  }

  @override
  Future<List<SplatServerAsset>> searchByName(String name, {int size = 50}) async {
    calls.add('search $name');
    return [
      for (final held in assets.values.toList().reversed)
        if (held.asset.originalFileName.contains(name)) held.asset,
    ];
  }

  /// Called by each head read with its cancel, before it answers
  Future<void> Function(bool Function()? cancelled)? onHead;

  @override
  Future<Uint8List?> head(String assetId, int length, {bool Function()? cancelled}) async {
    calls.add('head $assetId');
    await onHead?.call(cancelled);
    if (cancelled?.call() ?? false) {
      return null;
    }
    final bytes = assets[assetId]?.bytes;
    return bytes == null ? null : Uint8List.sublistView(bytes, 0, bytes.length < length ? bytes.length : length);
  }

  @override
  Future<SplatBulkAnswer> bulkCheck(String id, String sha1) async {
    calls.add('bulk $sha1');
    final given = bulkAnswer;
    if (given != null) {
      return given;
    }
    for (final held in assets.values) {
      if (sha1Of(held.bytes) == sha1) {
        return SplatBulkAnswer(accept: false, assetId: held.asset.id, isTrashed: held.asset.isTrashed);
      }
    }
    return const SplatBulkAnswer(accept: true);
  }

  @override
  Future<UploadResult> upload(
    UploadSource source, {
    Completer<void>? cancel,
    void Function(int, int)? onProgress,
  }) async {
    calls.add('upload ${source.filename}');
    final body = Uint8List.fromList(await source.openRead().expand((chunk) => chunk).toList());
    uploads.add((source: source, body: body));
    final answer = this.answer?.call(source);
    if (answer != null) {
      return answer;
    }
    final id = 'asset-${++next}';
    assets[id] = (
      asset: SplatServerAsset(id: id, originalFileName: source.filename, createdAt: source.createdAt),
      bytes: body,
    );
    return UploadResult.success(remoteAssetId: id, statusCode: 201);
  }

  @override
  Future<bool> albumExists(String id) async {
    calls.add('album? $id');
    return albums.containsKey(id);
  }

  @override
  Future<String> createAlbum(String name) async {
    calls.add('create album $name');
    final id = 'album-${albums.length + 1}';
    albums[id] = [];
    return id;
  }

  @override
  Future<void> addToAlbum(String albumId, String assetId) async {
    calls.add('add $assetId to $albumId');
    albums[albumId]!.add(assetId);
  }
}

String sha1Of(List<int> bytes) => sha1.convert(bytes).toString();
