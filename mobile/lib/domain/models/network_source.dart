// Network shares (SMB, WebDAV, DLNA media servers): a source is a share the user added, an entry is a file or a folder
// on it. Media of a share play straight from it through the local media bridge; nothing is copied to the device.

import 'dart:convert';

/// The stored name of each type is its [Enum.name]: an older build drops a source of a type it does not know
enum NetworkSourceType { smb, webdav, dlna }

/// A share the user added. The password lives in the secure storage under [secretKey], never in the Store.
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
  });

  /// Random id, stable for the life of the source; also the key of its password in the secure storage
  final String id;
  final NetworkSourceType type;

  /// What the user calls it
  final String name;

  /// SMB: the server name or address. WebDAV: the server name or address of the base URL. DLNA: the one of the device
  /// description URL.
  final String host;

  /// Null for the default port of the type (445 for SMB, 80 or 443 for WebDAV and DLNA)
  final int? port;

  /// SMB share name. WebDAV: the path of the base URL (for example "/remote.php/dav/files/alice"). DLNA: the path of
  /// the device description URL with its query ("/rootDesc.xml", "/dlna/7d2c.../description.xml").
  final String share;

  /// Folder inside the share the browser starts from, "/" for its root
  final String rootPath;

  /// Empty for DLNA, which has no authentication
  final String username;

  /// WebDAV over HTTPS, DLNA with an https description URL
  final bool useTls;

  /// What the server tells about itself on the network, to find it again when its address changes (see
  /// NetworkSourceRelocator): the UPnP UDN ("uuid:...") of a DLNA media server, the TXT id of a phone share. Null for
  /// a share typed in by hand.
  final String? discoveryId;

  String get secretKey => 'network_source_password_$id';

  Map<String, Object?> toJson() => {
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
  };

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
    );
  }

  static String encodeList(List<NetworkSource> sources) => jsonEncode(sources.map((s) => s.toJson()).toList());

  static List<NetworkSource> decodeList(String? json) {
    if (json == null || json.isEmpty) {
      return const [];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    return decoded is List ? decoded.map(fromJson).whereType<NetworkSource>().toList() : const [];
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
