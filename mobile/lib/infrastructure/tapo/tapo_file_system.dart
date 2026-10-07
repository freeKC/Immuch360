// The NetworkFileSystem of a Tapo camera: the days of its memory card as folders, the clips of a day as files, which
// the bridge serves once fetched (see TapoRecordings). Opening does no network I/O: the login happens on the first
// call that needs it, so that its errors reach the camera page as TapoCameraException.
//
// A clip not fetched yet answers isNotFound, so that the media bridge never waits on the camera (a player gives up
// after a few seconds); the day page fetches it first (TapoRecordings.fetch), then opens the bridge URL of the file.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_clip_cache.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_worker.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('TapoFileSystem');

/// `/yyyy-mm-dd/<start>-<end>.mov`
final _clipPath = RegExp(r'^/(\d{4}-\d{2}-\d{2})/(\d{1,12})-(\d{1,12})\.mov$');
final _dayPath = RegExp(r'^/(\d{4}-\d{2}-\d{2})/?$');

class TapoFileSystem implements NetworkFileSystem, TapoRecordings {
  TapoFileSystem._(this.source, this._password, this._client, this._camera, this._worker);

  @override
  final NetworkSource source;
  final String _password;
  final TapoControlClient _client;

  /// The cache folder of this camera
  final Directory _camera;
  final TapoMediaWorker _worker;
  bool _closed = false;

  /// [password] is the password of the TP-Link account; without it the recordings cannot be read
  static Future<NetworkFileSystem> open(NetworkSource source, String? password) => openWith(source, password);

  /// [open] with what the tests replace
  @visibleForTesting
  static Future<TapoFileSystem> openWith(
    NetworkSource source,
    String? password, {
    TapoControlClient? client,
    TapoMediaWorker? worker,
    Future<Directory> Function() cacheRoot = getApplicationCacheDirectory,
  }) async {
    if (password == null || password.isEmpty) {
      throw const NetworkFileSystemException('No password', isAuthentication: true);
    }
    final Directory camera;
    try {
      camera = await tapoCameraCacheDirectory(source.id, cacheRoot: cacheRoot);
    } on ArgumentError {
      throw const NetworkFileSystemException('Not a camera of this app', isNotFound: true);
    }
    return TapoFileSystem._(
      source,
      password,
      client ??
          TapoControlClient(
            sourceId: source.id,
            host: source.host,
            password: password,
            known: source.camera ?? const TapoCameraInfo(),
          ),
      camera,
      worker ?? TapoMediaWorker.instance,
    );
  }

  TapoMediaTarget get _target => TapoMediaTarget(
    host: source.host,
    password: _password,
    playerId: tapoPlayerId(source.id),
    port: _client.info.mediaPort,
  );

  // TapoRecordings

  @override
  TapoCameraInfo get info => _client.info;

  @override
  Future<TapoCameraDetails> details() => _client.details();

  @override
  Future<TapoCardStatus> cardStatus() => _client.cardStatus();

  @override
  Future<List<String>> days({bool refresh = false}) => _client.days(refresh: refresh);

  @override
  Future<List<TapoClip>> clips(String day, {bool refresh = false}) => _client.clips(day, refresh: refresh);

  /// The media port of the camera is only opened after a login through its pinned certificate in this run: its Digest
  /// exchange travels in clear (see TapoSessionCache)
  Future<void> _ensureMediaAllowed() async {
    await _client.ensureLoggedIn();
    if (!_client.isVerified) {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'certificate');
    }
  }

  @override
  Future<Uint8List?> thumbnail(TapoClip clip) async {
    if (clip.kind == TapoClipKind.continuous) {
      // A continuous recording has no picture: the camera stays silent until the request times out
      return null;
    }
    final start = clip.start.millisecondsSinceEpoch ~/ 1000;
    final file = tapoThumbnailFile(_camera, start);
    if (file.existsSync()) {
      try {
        return await file.readAsBytes();
      } on FileSystemException catch (error) {
        _log.fine('A kept thumbnail could not be read: $error');
      }
    }
    try {
      await _ensureMediaAllowed();
    } on TapoCameraException catch (error) {
      _log.fine('No thumbnails from the camera: $error');
      return null;
    }
    return _worker.thumbnail(_target, start: start, path: file.path);
  }

  @override
  bool isFetched(TapoClip clip) => _clipFile(clip).existsSync();

  File _clipFile(TapoClip clip) =>
      tapoClipFile(_camera, clip.start.millisecondsSinceEpoch ~/ 1000, clip.end.millisecondsSinceEpoch ~/ 1000);

  @override
  Future<void> fetch(TapoClip clip, {void Function(double progress)? onProgress, Future<void>? cancel}) async {
    final file = _clipFile(clip);
    if (file.existsSync()) {
      onProgress?.call(1);
      return;
    }
    await _ensureMediaAllowed();
    final zone = await _client.zone();
    await _worker.fetchClip(
      _target,
      start: clip.start.millisecondsSinceEpoch ~/ 1000,
      end: clip.end.millisecondsSinceEpoch ~/ 1000,
      outPath: file.path,
      creation: clip.start,
      zoneOffset: zone.offsetAt(clip.start),
      onProgress: onProgress,
      cancel: cancel,
    );
    try {
      await trimTapoClipCache(_camera.parent, keep: file.path);
    } catch (error, stackTrace) {
      _log.warning('Could not keep the fetched clips under their limit', error, stackTrace);
    }
  }

  @override
  Future<void> deleteCopy(TapoClip clip) async {
    try {
      await _clipFile(clip).delete();
    } on PathNotFoundException {
      // Not on this device
    }
  }

  @override
  Future<int> cacheBytes() => tapoCameraCacheBytes(_camera);

  @override
  Future<void> clearCache() async {
    try {
      await _camera.delete(recursive: true);
    } on PathNotFoundException {
      // Nothing fetched
    }
  }

  // NetworkFileSystem

  @override
  Future<List<NetworkEntry>> list(String path) async {
    if (path == '/' || path.isEmpty) {
      final days = await _guard(_client.days);
      return [
        for (final day in days)
          NetworkEntry(sourceId: source.id, path: '/$day', isDirectory: true, modified: _dayStart(day)),
      ]..sort(compareNetworkEntries);
    }
    final day = _dayPath.firstMatch(path)?.group(1);
    if (day == null || tapoParseDay(day) == null) {
      throw NetworkFileSystemException('No folder $path', isNotFound: true);
    }
    final clips = await _guard(() => _client.clips(day));
    return [
      for (final clip in clips)
        NetworkEntry(
          sourceId: source.id,
          path: clip.path,
          isDirectory: false,
          size: _sizeOf(_clipFile(clip)),
          modified: clip.start,
          mimeType: 'video/quicktime',
          durationMs: clip.duration.inMilliseconds,
        ),
    ]..sort(compareNetworkEntries);
  }

  static DateTime? _dayStart(String day) {
    final date = tapoParseDay(day);
    return date == null ? null : DateTime.utc(date.year, date.month, date.day);
  }

  static int? _sizeOf(File file) {
    try {
      return file.lengthSync();
    } on FileSystemException {
      return null;
    }
  }

  /// The fetched file of the clip at [path], null when [path] is not a clip path
  File? _fileOf(String path) {
    final match = _clipPath.firstMatch(path);
    if (match == null || tapoParseDay(match.group(1)!) == null) {
      return null;
    }
    final start = int.parse(match.group(2)!);
    final end = int.parse(match.group(3)!);
    return end > start ? tapoClipFile(_camera, start, end) : null;
  }

  @override
  Future<NetworkEntry> stat(String path) async {
    if (path == '/' || _dayPath.hasMatch(path)) {
      return NetworkEntry(sourceId: source.id, path: path, isDirectory: true);
    }
    final file = _fileOf(path);
    final size = file == null ? null : _sizeOf(file);
    if (file == null || size == null) {
      throw NetworkFileSystemException('No fetched clip at $path', isNotFound: true);
    }
    // The clips played last stay longest in the cache (see trimTapoClipCache)
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException catch (error) {
      _log.finest('Could not mark a clip as played: $error');
    }
    final start = int.parse(_clipPath.firstMatch(path)!.group(2)!);
    return NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: size,
      modified: DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true),
      mimeType: 'video/quicktime',
    );
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final file = _fileOf(path);
    if (file == null) {
      throw NetworkFileSystemException('No fetched clip at $path', isNotFound: true);
    }
    RandomAccessFile? opened;
    try {
      opened = await file.open();
      final size = await opened.length();
      if (offset >= size || length <= 0) {
        return Uint8List(0);
      }
      await opened.setPosition(offset);
      return await opened.read(length < size - offset ? length : size - offset);
    } on PathNotFoundException {
      throw NetworkFileSystemException('No fetched clip at $path', isNotFound: true);
    } finally {
      await opened?.close();
    }
  }

  /// [call] with the errors of the camera as the errors of a share
  Future<T> _guard<T>(Future<T> Function() call) async {
    if (_closed) {
      throw const NetworkFileSystemException('The connection to the camera was closed');
    }
    try {
      return await call();
    } on TapoCameraException catch (error) {
      throw NetworkFileSystemException(
        'The camera refused the request (${error.kind.name}${error.code == null ? '' : ' ${error.code}'})',
        isAuthentication: const {
          TapoErrorKind.wrongPassword,
          TapoErrorKind.locked,
          TapoErrorKind.notOwner,
          TapoErrorKind.mediaLocked,
        }.contains(error.kind),
      );
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _client.close();
  }
}
