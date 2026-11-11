// A copy of a film of a share kept on this device (request 5 of the Plex films study of 10 November 2026: "Download
// the film"). The copy lives in the app's own storage, never in the gallery (decision 4 a: the phone backup would send
// an 8 GB film to Immich), or in the download folder of a computer. It is the original file of the server, whole.

import 'package:immich_mobile/domain/models/network_source.dart';

/// Where a copy stands
enum FilmDownloadState {
  /// Asked, waiting for the copy before it to end
  queued,

  /// Being copied
  running,

  /// Stopped by the user; the bytes copied so far are kept
  paused,

  /// On mobile data while "Download only on Wi-Fi" is on: goes on by itself on Wi-Fi
  waitingForWifi,

  /// Stopped by a failure the user has to see (see [FilmDownloadFailure]); the bytes copied so far are kept
  failed,

  /// Whole on this device
  done,
}

/// Why a copy stopped
enum FilmDownloadFailure {
  /// The owner of the Plex server does not allow this account to download (HTTP 403 with download=1)
  forbidden,

  /// Not enough room on this device
  noSpace,

  /// The server could not be reached after several tries
  unreachable,

  /// The file is no longer on the server
  gone,

  /// The server knows the film but cannot read its file now (a volume not mounted after a reboot of the NAS)
  unreadable,

  /// Anything else
  failed,
}

/// One film copied, or being copied, to this device
class FilmDownload {
  const FilmDownload({
    required this.id,
    required this.sourceId,
    required this.path,
    required this.fileName,
    required this.localPath,
    required this.state,
    required this.addedAt,
    this.title,
    this.size,
    this.modified,
    this.mimeType,
    this.width,
    this.height,
    this.durationMs,
    this.identity,
    this.received = 0,
    this.failure,
    this.completedAt,
    this.mobileDataThisTime = false,
  });

  /// Random, the name of the copy's files in the app's storage
  final String id;
  final String sourceId;

  /// The path of the film in its share, as the browser lists it
  final String path;

  /// The name of the file on the server
  final String fileName;

  /// The title to show, null for the file name (the films page of lot A gives the Plex title)
  final String? title;

  /// Where the whole copy is, or will be once complete: in the app's storage, or in the download folder of a computer
  final String localPath;

  final FilmDownloadState state;

  /// The size of the file on the server, null until the server tells it
  final int? size;

  /// The date the share gives the file (Plex: when it was added), for the watch progress shared with the streamed film
  final DateTime? modified;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? durationMs;

  /// What the server tells of the version of the file (see NetworkDownloadStream.identity), null before the first answer
  final String? identity;

  /// Bytes copied so far
  final int received;
  final FilmDownloadFailure? failure;

  /// When the copy was asked, and when it completed
  final DateTime addedAt;
  final DateTime? completedAt;

  /// "Download over mobile data this time": this copy goes on without Wi-Fi
  final bool mobileDataThisTime;

  /// The title shown: the one given, else the name of the file without its extension
  String get shownTitle {
    final given = title?.trim();
    if (given != null && given.isNotEmpty) {
      return given;
    }
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /// The share and path that identify the film, whatever page lists it
  String get key => keyOf(sourceId, path);

  static String keyOf(String sourceId, String path) => '$sourceId\n$path';

  bool get isDone => state == FilmDownloadState.done;

  /// Whether the copy goes on by itself (now or once the copy before it, or the Wi-Fi, is there)
  bool get isActive =>
      state == FilmDownloadState.running ||
      state == FilmDownloadState.queued ||
      state == FilmDownloadState.waitingForWifi;

  /// Between 0 and 1, null while the size is not known
  double? get fraction {
    final total = size;
    if (isDone) {
      return 1;
    }
    if (total == null || total <= 0) {
      return null;
    }
    return (received / total).clamp(0, 1).toDouble();
  }

  /// The entry of the film as its share listed it, for the player, the watch progress and the upload records
  NetworkEntry get entry => NetworkEntry(
    sourceId: sourceId,
    path: path,
    isDirectory: false,
    size: size,
    modified: modified,
    mimeType: mimeType,
    width: width,
    height: height,
    durationMs: durationMs,
  );

  FilmDownload copyWith({
    FilmDownloadState? state,
    int? size,
    String? identity,
    int? received,
    FilmDownloadFailure? failure,
    bool clearFailure = false,
    DateTime? completedAt,
    bool? mobileDataThisTime,
    String? localPath,
  }) => FilmDownload(
    id: id,
    sourceId: sourceId,
    path: path,
    fileName: fileName,
    title: title,
    localPath: localPath ?? this.localPath,
    state: state ?? this.state,
    addedAt: addedAt,
    size: size ?? this.size,
    modified: modified,
    mimeType: mimeType,
    width: width,
    height: height,
    durationMs: durationMs,
    identity: identity ?? this.identity,
    received: received ?? this.received,
    failure: clearFailure ? null : (failure ?? this.failure),
    completedAt: completedAt ?? this.completedAt,
    mobileDataThisTime: mobileDataThisTime ?? this.mobileDataThisTime,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'sourceId': sourceId,
    'path': path,
    'fileName': fileName,
    'title': ?title,
    'localPath': localPath,
    'state': state.name,
    'addedAt': addedAt.toUtc().millisecondsSinceEpoch,
    'size': ?size,
    'modified': ?modified?.toUtc().millisecondsSinceEpoch,
    'mimeType': ?mimeType,
    'width': ?width,
    'height': ?height,
    'durationMs': ?durationMs,
    'identity': ?identity,
    'received': received,
    'failure': ?failure?.name,
    'completedAt': ?completedAt?.toUtc().millisecondsSinceEpoch,
    if (mobileDataThisTime) 'mobileDataThisTime': true,
  };

  /// Null when [json] is not a copy this build can read
  static FilmDownload? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final sourceId = json['sourceId'];
    final path = json['path'];
    final fileName = json['fileName'];
    final localPath = json['localPath'];
    final addedAt = _date(json['addedAt']);
    if (id is! String || sourceId is! String || path is! String || fileName is! String || localPath is! String) {
      return null;
    }
    if (addedAt == null) {
      return null;
    }
    final state = FilmDownloadState.values.where((value) => value.name == json['state']).firstOrNull;
    if (state == null) {
      return null;
    }
    return FilmDownload(
      id: id,
      sourceId: sourceId,
      path: path,
      fileName: fileName,
      title: json['title'] is String ? json['title'] as String : null,
      localPath: localPath,
      state: state,
      addedAt: addedAt,
      size: _int(json['size']),
      modified: _date(json['modified']),
      mimeType: json['mimeType'] is String ? json['mimeType'] as String : null,
      width: _int(json['width']),
      height: _int(json['height']),
      durationMs: _int(json['durationMs']),
      identity: json['identity'] is String ? json['identity'] as String : null,
      received: _int(json['received']) ?? 0,
      failure: FilmDownloadFailure.values.where((value) => value.name == json['failure']).firstOrNull,
      completedAt: _date(json['completedAt']),
      mobileDataThisTime: json['mobileDataThisTime'] == true,
    );
  }

  static int? _int(Object? value) => value is int ? value : null;

  static DateTime? _date(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true) : null;
}
