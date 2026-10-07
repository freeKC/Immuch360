// Network shares (SMB, WebDAV, DLNA media servers, Plex Media Servers) and Tapo cameras: a source is a share or a
// camera the user added, an entry is a file or a folder on it. Media of a share play straight from it through the
// local media bridge; nothing is copied to the device.

import 'dart:convert';

import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';

/// The stored name of each type is its [Enum.name]. Builds 19 and older know smb, webdav and dlna only and drop any
/// other type they read, so the later types are stored in a list of their own (see StoreKey.networkSourcesExtra)
enum NetworkSourceType {
  smb,
  webdav,
  dlna,
  plex,
  tapo;

  /// Stored in StoreKey.networkSources, the list that builds 19 and older read and write back
  bool get inLegacyList => this == smb || this == webdav || this == dlna;
}

/// A stored list: the sources this build reads, and the entries of a type it does not know, kept as they are so that
/// a later build finds them again
typedef StoredNetworkSources = ({List<NetworkSource> sources, List<Map<String, Object?>> unknown});

/// A share or a camera the user added. The password lives in the secure storage under [secretKey], never in the
/// Store.
class NetworkSource {
  const NetworkSource({
    required this.id,
    required this.type,
    required this.name,
    required this.host,
    this.port,
    this.share = '',
    this.rootPath = '/',
    this.username = '',
    this.useTls = false,
    this.discoveryId,
    this.plex,
    this.camera,
    this.extraJson = const {},
  });

  /// Random id, stable for the life of the source; also the key of its password in the secure storage
  final String id;
  final NetworkSourceType type;

  /// What the user calls it
  final String name;

  /// SMB: the server name or address. WebDAV: the server name or address of the base URL. DLNA: the one of the device
  /// description URL. Plex: the local IPv4 address of the server, empty when it was paired from outside home. Tapo:
  /// the address of the camera.
  final String host;

  /// Null for the default port of the type (445 for SMB, 80 or 443 for WebDAV and DLNA, 32400 for Plex, 443 for
  /// Tapo)
  final int? port;

  /// SMB share name. WebDAV: the path of the base URL (for example "/remote.php/dav/files/alice"). DLNA: the path of
  /// the device description URL with its query ("/rootDesc.xml", "/dlna/7d2c.../description.xml"). "" for Plex and
  /// Tapo.
  final String share;

  /// Folder inside the share the browser starts from, "/" for its root. Plex: "/" or "/<Section>". Tapo: "/".
  final String rootPath;

  /// Empty for DLNA, which has no authentication, and for Plex. Tapo: the user of the camera account (live view), ""
  /// when none.
  final String username;

  /// WebDAV over HTTPS, DLNA with an https description URL; always true for Plex and Tapo
  final bool useTls;

  /// What the server tells about itself on the network, to find it again when its address changes (see
  /// NetworkSourceRelocator): the UPnP UDN ("uuid:...") of a DLNA media server, the TXT id of a phone share, the
  /// machineIdentifier (40 hex digits) of a Plex server, the MAC address of a Tapo camera in lower case
  /// ("aa-bb-cc-dd-ee-ff"). Null for a share typed in by hand.
  final String? discoveryId;

  /// Required for a Plex server (JSON key "plex"), null for the other types
  final PlexServerInfo? plex;

  /// What the app learned about a Tapo camera (JSON key "camera"); null for the other types, and for a camera saved
  /// with its camera account only until a login on its TP-Link account
  final TapoCameraInfo? camera;

  /// The keys of the stored object this build does not know, written back first by [toJson] (the known keys
  /// overwrite them) so that the later build that wrote them finds them again
  final Map<String, Object?> extraJson;

  static const _knownKeys = {
    'id',
    'type',
    'name',
    'host',
    'port',
    'share',
    'rootPath',
    'username',
    'useTls',
    'discoveryId',
    'plex',
    'camera',
  };

  /// SMB and WebDAV: the password. Plex: the token. Tapo: the password of the TP-Link account (recordings).
  String get secretKey => 'network_source_password_$id';

  /// Tapo: the password of the camera account (live view); unused by the other types
  String get cameraSecretKey => 'network_source_camera_password_$id';

  Map<String, Object?> toJson() => {
    ...extraJson,
    'id': id,
    'type': type.name,
    'name': name,
    'host': host,
    'port': port,
    'share': share,
    'rootPath': rootPath,
    'username': username,
    'useTls': useTls,
    if (discoveryId != null) 'discoveryId': discoveryId,
    if (plex != null) 'plex': plex!.toJson(),
    if (camera != null) 'camera': camera!.toJson(),
  };

  /// Null when [json] is not a source of a type this build knows, or misses what its type needs (the hash of a Plex
  /// server)
  static NetworkSource? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final type = NetworkSourceType.values.where((t) => t.name == json['type']).firstOrNull;
    final name = json['name'];
    final host = json['host'];
    if (id is! String || type == null || name is! String || host is! String) {
      return null;
    }
    final plex = PlexServerInfo.fromJson(json['plex']);
    if (type == NetworkSourceType.plex && plex == null) {
      // Without the hash of its certificate the token could go to any server
      return null;
    }
    final camera = json['camera'];
    final discoveryId = json['discoveryId'];
    return NetworkSource(
      id: id,
      type: type,
      name: name,
      host: host,
      port: json['port'] is int ? json['port'] as int : null,
      share: json['share'] is String ? json['share'] as String : '',
      rootPath: json['rootPath'] is String ? json['rootPath'] as String : '/',
      username: json['username'] is String ? json['username'] as String : '',
      useTls: json['useTls'] == true,
      discoveryId: discoveryId is String && discoveryId.isNotEmpty ? discoveryId : null,
      plex: plex,
      camera: camera is Map ? TapoCameraInfo.fromJson(camera) : null,
      extraJson: Map.unmodifiable({
        for (final entry in json.entries)
          if (entry.key is String && !_knownKeys.contains(entry.key)) entry.key as String: entry.value,
      }),
    );
  }

  static String encodeList(List<NetworkSource> sources) => jsonEncode(sources.map((s) => s.toJson()).toList());

  static List<NetworkSource> decodeList(String? json) => decodeStored(json).sources;

  /// Entries of a known type that do not validate are dropped (and logged by the caller, through [onDropped]); entries
  /// of an unknown type go to `unknown`
  static StoredNetworkSources decodeStored(String? json, {void Function(Object? entry)? onDropped}) {
    if (json == null || json.isEmpty) {
      return (sources: const [], unknown: const []);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      onDropped?.call(null);
      return (sources: const [], unknown: const []);
    }
    if (decoded is! List) {
      onDropped?.call(decoded);
      return (sources: const [], unknown: const []);
    }
    final sources = <NetworkSource>[];
    final unknown = <Map<String, Object?>>[];
    for (final entry in decoded) {
      final type = entry is Map ? entry['type'] : null;
      if (entry is Map && type is String && type.isNotEmpty && !NetworkSourceType.values.any((t) => t.name == type)) {
        // A type of a later build: kept whole, whatever it holds
        unknown.add(Map<String, Object?>.unmodifiable(entry.map((key, value) => MapEntry('$key', value))));
        continue;
      }
      final source = fromJson(entry);
      if (source == null) {
        onDropped?.call(entry);
      } else {
        sources.add(source);
      }
    }
    return (sources: List.unmodifiable(sources), unknown: List.unmodifiable(unknown));
  }

  /// Null when both lists are empty
  static String? encodeStored(List<NetworkSource> sources, List<Map<String, Object?>> unknown) {
    if (sources.isEmpty && unknown.isEmpty) {
      return null;
    }
    return jsonEncode([...sources.map((s) => s.toJson()), ...unknown]);
  }

  NetworkSource copyWith({
    String? name,
    String? host,
    int? port,
    bool clearPort = false,
    String? share,
    String? rootPath,
    String? username,
    bool? useTls,
    String? discoveryId,
    bool clearDiscoveryId = false,
    PlexServerInfo? plex,
    TapoCameraInfo? camera,
  }) => NetworkSource(
    id: id,
    type: type,
    name: name ?? this.name,
    host: host ?? this.host,
    port: clearPort ? null : (port ?? this.port),
    share: share ?? this.share,
    rootPath: rootPath ?? this.rootPath,
    username: username ?? this.username,
    useTls: useTls ?? this.useTls,
    discoveryId: clearDiscoveryId ? null : (discoveryId ?? this.discoveryId),
    plex: plex ?? this.plex,
    camera: camera ?? this.camera,
    extraJson: extraJson,
  );
}

/// A file or folder on a share. [path] is absolute inside the share, "/" separated, starting with "/".
class NetworkEntry {
  const NetworkEntry({
    required this.sourceId,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modified,
    this.mimeType,
    this.thumbnailUrl,
    this.width,
    this.height,
    this.durationMs,
  });

  final String sourceId;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modified;

  /// From the server when it gives one, else from the extension (see [guessedMimeType])
  final String? mimeType;

  // What a server that indexes its media tells in its listings (a DLNA media server); null when it does not. Not
  // stored anywhere: an entry lives as long as the listing it came from.

  /// A small picture of the entry made by the server, a direct http URL of the share. Read in Dart only, never handed
  /// to the native players (they only ever get bridge URLs).
  final String? thumbnailUrl;

  /// Size of the picture or of the video frame, in pixels
  final int? width;
  final int? height;

  /// Length of a video
  final int? durationMs;

  String get name =>
      path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1).split('/').last : path.split('/').last;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static const imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'heic',
    'heif',
    'avif',
    'gif',
    'bmp',
    'tif',
    'tiff',
    'insp',
    // The equirect JPEG of the GoPro MAX 2
    '36p',
    'dng',
  };

  /// The raw videos of 360° cameras are MP4 files under names of their own: Insta360 .insv, GoPro .360, DJI .osv
  static const videoExtensions = {
    'mp4',
    'mov',
    'm4v',
    'mkv',
    'webm',
    'avi',
    '3gp',
    'mts',
    'm2ts',
    'insv',
    '360',
    'osv',
  };

  // MP4 files under the names of 360° cameras, the low resolution proxies (.lrv, .lrf) included, which are no media of
  // their own on the shares. The players decide by the content type for an extension they do not know: AVPlayer and
  // Media3 need video/mp4 for them, whatever the server says.
  static const _cameraMp4Extensions = {'insv', '360', 'osv', 'lrv', 'lrf'};

  bool get isImage => !isDirectory && imageExtensions.contains(extension);
  bool get isVideo => !isDirectory && videoExtensions.contains(extension);
  bool get isMedia => isImage || isVideo;

  /// A content type for the bridge and the players, from [mimeType] or the extension
  String get guessedMimeType {
    if (_cameraMp4Extensions.contains(extension)) {
      return 'video/mp4';
    }
    final given = mimeType;
    if (given != null && given.isNotEmpty && given != 'application/octet-stream') {
      return given;
    }
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      'avif' => 'image/avif',
      'gif' => 'image/gif',
      'bmp' => 'image/bmp',
      'tif' || 'tiff' => 'image/tiff',
      'dng' => 'image/x-adobe-dng',
      'insp' || '36p' => 'image/jpeg',
      'mp4' || 'm4v' => 'video/mp4',
      'mov' => 'video/quicktime',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'avi' => 'video/x-msvideo',
      '3gp' => 'video/3gpp',
      'mts' || 'm2ts' => 'video/mp2t',
      _ => 'application/octet-stream',
    };
  }
}
