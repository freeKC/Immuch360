// The answers of a Jellyfin or Emby server the app reads, as plain Dart: the public information of the server, a sign
// in, Quick Connect, the items of the libraries, their media sources and streams, and the conversion the server
// offers. Written from the HTTP API of the two products and from their answers on the release 49 bench (see
// test/fixtures/jellyfin/README.txt); no code of either product or of their clients. Every field is optional but the
// ids, and unknown fields are ignored: both products add fields from one version to the next.

/// The two products that speak this API
enum JellyfinProduct {
  jellyfin,
  emby;

  /// The name shown to the user ("Jellyfin", "Emby"): a product name, never a logo
  String get shownName => switch (this) {
    jellyfin => 'Jellyfin',
    emby => 'Emby',
  };

  static JellyfinProduct? byName(Object? name) => values.where((p) => p.name == name).firstOrNull;
}

final _serverId = RegExp(r'^[0-9a-f]{32}$');

/// Whether [id] is the id of a server: 32 lower case hex digits, as both products give it
bool isJellyfinServerId(String? id) => id != null && _serverId.hasMatch(id);

/// The ticks of both products are 100 ns
int? jellyfinTicksToMs(Object? ticks) => ticks is num && ticks >= 0 ? (ticks / 10000).round() : null;

int jellyfinMsToTicks(int ms) => ms * 10000;

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

int? _int(Object? value) => value is int ? value : (value is num ? value.round() : null);

bool? _bool(Object? value) => value is bool ? value : null;

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.map((key, value) => MapEntry('$key', value)) : const <String, Object?>{};

List<Map<String, Object?>> _maps(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is Map) _map(item),
      ]
    : const [];

/// GET /System/Info/Public, which needs no credential
class JellyfinPublicInfo {
  const JellyfinPublicInfo({
    required this.id,
    required this.product,
    this.serverName,
    this.version,
    this.startupWizardCompleted,
  });

  /// 32 hex digits, the id of the server: what tells it from another at the same address
  final String id;
  final JellyfinProduct product;
  final String? serverName;
  final String? version;

  /// False while the server's setup is not done (Jellyfin); null when the server does not tell (Emby)
  final bool? startupWizardCompleted;

  /// Null when [json] is not the answer of either product: no id of 32 hex digits, or no version. Jellyfin names
  /// itself in ProductName ("Jellyfin Server"); Emby has no ProductName at all (4.10 on the bench).
  static JellyfinPublicInfo? parse(Object? json) {
    final map = _map(json);
    final id = _string(map['Id'])?.toLowerCase();
    final version = _string(map['Version']);
    if (!isJellyfinServerId(id) || version == null) {
      return null;
    }
    final productName = _string(map['ProductName'])?.toLowerCase();
    final JellyfinProduct product;
    if (productName == null || productName.contains('emby')) {
      product = JellyfinProduct.emby;
    } else if (productName.contains('jellyfin')) {
      product = JellyfinProduct.jellyfin;
    } else {
      return null;
    }
    return JellyfinPublicInfo(
      id: id!,
      product: product,
      serverName: _string(map['ServerName']),
      version: version,
      startupWizardCompleted: _bool(map['StartupWizardCompleted']),
    );
  }
}

/// One user of GET /Users/Public (which Jellyfin leaves empty by default, Emby fills)
class JellyfinPublicUser {
  const JellyfinPublicUser({required this.id, required this.name, this.hasPassword = true});

  final String id;
  final String name;
  final bool hasPassword;

  static List<JellyfinPublicUser> parseList(Object? json) => [
    for (final user in json is List ? json.whereType<Map>().map(_map) : const <Map<String, Object?>>[])
      if (_string(user['Id']) case final id?)
        if (_string(user['Name']) case final name?)
          JellyfinPublicUser(id: id, name: name, hasPassword: _bool(user['HasPassword']) ?? true),
  ];
}

/// The answer of a sign in (AuthenticateByName, AuthenticateWithQuickConnect)
class JellyfinSignIn {
  const JellyfinSignIn({required this.accessToken, required this.userId, required this.userName, this.serverId});

  final String accessToken;
  final String userId;
  final String userName;
  final String? serverId;

  /// Null without a token or a user id
  static JellyfinSignIn? parse(Object? json) {
    final map = _map(json);
    final token = _string(map['AccessToken']);
    final user = _map(map['User']);
    final userId = _string(user['Id']);
    if (token == null || userId == null) {
      return null;
    }
    return JellyfinSignIn(
      accessToken: token,
      userId: userId,
      userName: _string(user['Name']) ?? '',
      serverId: _string(map['ServerId'])?.toLowerCase(),
    );
  }
}

/// A Quick Connect request: its [code] for the user, its [secret] for the app only (never shown, never logged)
class JellyfinQuickConnect {
  const JellyfinQuickConnect({required this.secret, required this.code, this.authenticated = false});

  final String secret;
  final String code;
  final bool authenticated;

  static JellyfinQuickConnect? parse(Object? json) {
    final map = _map(json);
    final secret = _string(map['Secret']);
    final code = _string(map['Code']);
    if (secret == null || code == null) {
      return null;
    }
    return JellyfinQuickConnect(secret: secret, code: code, authenticated: map['Authenticated'] == true);
  }
}

/// What the server keeps of a user and an item: the place reached, whether it was played
class JellyfinUserData {
  const JellyfinUserData({this.positionMs, this.played = false, this.playCount = 0});

  /// From PlaybackPositionTicks; null or 0 when not started
  final int? positionMs;
  final bool played;
  final int playCount;

  static JellyfinUserData? parse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final map = _map(json);
    return JellyfinUserData(
      positionMs: jellyfinTicksToMs(map['PlaybackPositionTicks']),
      played: map['Played'] == true,
      playCount: _int(map['PlayCount']) ?? 0,
    );
  }
}

/// One stream of a media source (video, audio, subtitle)
class JellyfinMediaStream {
  const JellyfinMediaStream({
    required this.type,
    this.index,
    this.codec,
    this.profile,
    this.isDefault = false,
    this.width,
    this.height,
    this.channels,
    this.language,
    this.dvProfile,
    this.videoRange,
  });

  /// "Video", "Audio", "Subtitle", "EmbeddedImage"
  final String type;
  final int? index;

  /// Lower case as the servers give it: "h264", "hevc", "dts", "aac"
  final String? codec;

  /// As the server gives it: "High", "Main 10", "DTS-HD MA", "LC"
  final String? profile;
  final bool isDefault;
  final int? width;
  final int? height;
  final int? channels;
  final String? language;
  final int? dvProfile;

  /// "SDR", "HDR"
  final String? videoRange;

  bool get isVideo => type == 'Video';
  bool get isAudio => type == 'Audio';

  static JellyfinMediaStream? parse(Map<String, Object?> map) {
    final type = _string(map['Type']);
    if (type == null) {
      return null;
    }
    return JellyfinMediaStream(
      type: type,
      index: _int(map['Index']),
      codec: _string(map['Codec'])?.toLowerCase(),
      profile: _string(map['Profile']),
      isDefault: map['IsDefault'] == true,
      width: _int(map['Width']),
      height: _int(map['Height']),
      channels: _int(map['Channels']),
      language: _string(map['Language']),
      dvProfile: _int(map['DvProfile']),
      videoRange: _string(map['VideoRange']),
    );
  }
}

/// One file of an item, as PlaybackInfo and the item lists with fields=MediaSources give it
class JellyfinMediaSource {
  const JellyfinMediaSource({
    required this.id,
    this.path,
    this.container,
    this.size,
    this.video3DFormat,
    this.streams = const [],
    this.transcodingUrl,
    this.transcodingSubProtocol,
    this.defaultAudioStreamIndex,
    this.runTimeMs,
  });

  final String id;

  /// The path on the server's disk; the app reads its base name only (the words "360", "sbs" of a file name)
  final String? path;

  /// "mp4", "mkv", or a list such as "mov,mp4,m4a,3gp,3g2,mj2"
  final String? container;
  final int? size;

  /// HalfSideBySide, FullSideBySide, FullTopAndBottom, HalfTopAndBottom, MVC; null for a flat film
  final String? video3DFormat;
  final List<JellyfinMediaStream> streams;

  /// The server's own conversion of this source (PlaybackInfo with a device profile): a path with its query, which
  /// holds a key (ApiKey or api_key) the app removes before use. Never logged.
  final String? transcodingUrl;

  /// "hls" when [transcodingUrl] is an HLS playlist
  final String? transcodingSubProtocol;
  final int? defaultAudioStreamIndex;
  final int? runTimeMs;

  JellyfinMediaStream? get video => streams.where((s) => s.isVideo).firstOrNull;

  static JellyfinMediaSource? parse(Map<String, Object?> map) {
    final id = _string(map['Id']);
    if (id == null) {
      return null;
    }
    return JellyfinMediaSource(
      id: id,
      path: _string(map['Path']),
      container: _string(map['Container'])?.toLowerCase(),
      size: _int(map['Size']),
      video3DFormat: _string(map['Video3DFormat']),
      streams: [for (final stream in _maps(map['MediaStreams'])) ?JellyfinMediaStream.parse(stream)],
      transcodingUrl: _string(map['TranscodingUrl']),
      transcodingSubProtocol: _string(map['TranscodingSubProtocol'])?.toLowerCase(),
      defaultAudioStreamIndex: _int(map['DefaultAudioStreamIndex']),
      runTimeMs: jellyfinTicksToMs(map['RunTimeTicks']),
    );
  }
}

/// An item of a library: a library itself (CollectionFolder), a folder, a film, a series, a season, an episode, a
/// video, a photo
class JellyfinItem {
  const JellyfinItem({
    required this.id,
    this.name = '',
    this.type,
    this.isFolder = false,
    this.collectionType,
    this.mediaType,
    this.productionYear,
    this.runTimeMs,
    this.overview,
    this.primaryImageTag,
    this.userData,
    this.mediaSources = const [],
    this.video3DFormat,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.indexNumber,
    this.parentIndexNumber,
    this.width,
    this.height,
    this.path,
    this.container,
  });

  final String id;
  final String name;

  /// "CollectionFolder", "Folder", "Movie", "Series", "Season", "Episode", "Video", "Photo", "PhotoAlbum",
  /// "MusicVideo", "Audio"...
  final String? type;
  final bool isFolder;

  /// For a library: movies, tvshows, homevideos, photos, musicvideos, folders, boxsets, music, books, livetv,
  /// playlists; null for a library of mixed content and for any other item
  final String? collectionType;

  /// "Video", "Photo", "Audio"
  final String? mediaType;
  final int? productionYear;
  final int? runTimeMs;
  final String? overview;

  /// The tag of the Primary image (a poster, a photo's own picture); null when the item has none
  final String? primaryImageTag;
  final JellyfinUserData? userData;
  final List<JellyfinMediaSource> mediaSources;
  final String? video3DFormat;
  final String? seriesId;
  final String? seriesName;
  final String? seasonId;

  /// The episode number of an episode, the season number of a season
  final int? indexNumber;

  /// The season number of an episode
  final int? parentIndexNumber;
  final int? width;
  final int? height;

  /// The path on the server's disk, when the server gives it (photos have no media source but a path)
  final String? path;
  final String? container;

  bool get isMovie => type == 'Movie';
  bool get isSeries => type == 'Series';
  bool get isSeason => type == 'Season';
  bool get isEpisode => type == 'Episode';
  bool get isVideo =>
      !isFolder &&
      (mediaType == 'Video' || type == 'Movie' || type == 'Episode' || type == 'Video' || type == 'MusicVideo');
  bool get isPhoto => !isFolder && (mediaType == 'Photo' || type == 'Photo');

  JellyfinMediaSource? get firstSource => mediaSources.firstOrNull;

  static JellyfinItem? parse(Object? json) {
    final map = _map(json);
    final id = _string(map['Id']);
    if (id == null) {
      return null;
    }
    final imageTags = _map(map['ImageTags']);
    return JellyfinItem(
      id: id,
      name: _string(map['Name']) ?? '',
      type: _string(map['Type']),
      isFolder: map['IsFolder'] == true,
      collectionType: _string(map['CollectionType'])?.toLowerCase(),
      mediaType: _string(map['MediaType']),
      productionYear: _int(map['ProductionYear']),
      runTimeMs: jellyfinTicksToMs(map['RunTimeTicks']),
      overview: _string(map['Overview']),
      primaryImageTag: _string(imageTags['Primary']),
      userData: JellyfinUserData.parse(map['UserData']),
      mediaSources: [for (final source in _maps(map['MediaSources'])) ?JellyfinMediaSource.parse(source)],
      video3DFormat: _string(map['Video3DFormat']),
      seriesId: _string(map['SeriesId']),
      seriesName: _string(map['SeriesName']),
      seasonId: _string(map['SeasonId']),
      indexNumber: _int(map['IndexNumber']),
      parentIndexNumber: _int(map['ParentIndexNumber']),
      width: _int(map['Width']),
      height: _int(map['Height']),
      path: _string(map['Path']),
      container: _string(map['Container'])?.toLowerCase(),
    );
  }
}

/// A page of items: {Items, TotalRecordCount, StartIndex}
class JellyfinItemsPage {
  const JellyfinItemsPage({required this.items, this.totalRecordCount, this.startIndex = 0});

  final List<JellyfinItem> items;

  /// Null when the server does not count
  final int? totalRecordCount;
  final int startIndex;

  /// A bare list of items is read too (some routes of older servers answer one)
  static JellyfinItemsPage parse(Object? json) {
    if (json is List) {
      return JellyfinItemsPage(items: [for (final item in json) ?JellyfinItem.parse(item)]);
    }
    final map = _map(json);
    return JellyfinItemsPage(
      items: [for (final item in _maps(map['Items'])) ?JellyfinItem.parse(item)],
      totalRecordCount: _int(map['TotalRecordCount']),
      startIndex: _int(map['StartIndex']) ?? 0,
    );
  }
}

/// POST /Items/{id}/PlaybackInfo
class JellyfinPlaybackInfo {
  const JellyfinPlaybackInfo({required this.mediaSources, this.playSessionId});

  final List<JellyfinMediaSource> mediaSources;
  final String? playSessionId;

  static JellyfinPlaybackInfo parse(Object? json) {
    final map = _map(json);
    return JellyfinPlaybackInfo(
      mediaSources: [for (final source in _maps(map['MediaSources'])) ?JellyfinMediaSource.parse(source)],
      playSessionId: _string(map['PlaySessionId']),
    );
  }
}

/// One answer to the discovery question on UDP 7359: {Address, Id, Name} (Jellyfin adds EndpointAddress). [Address]
/// is the server's own idea of its address, the container's in Docker bridge mode: only its scheme and port are kept.
class JellyfinDiscoveryAnswer {
  const JellyfinDiscoveryAnswer({required this.id, this.name, this.useTls = false, this.port});

  final String id;
  final String? name;
  final bool useTls;

  /// The port of Address, null when it has none
  final int? port;

  static JellyfinDiscoveryAnswer? parse(Object? json) {
    final map = _map(json);
    final id = _string(map['Id'])?.toLowerCase();
    if (!isJellyfinServerId(id)) {
      return null;
    }
    final address = Uri.tryParse(_string(map['Address']) ?? '');
    final scheme = address?.scheme.toLowerCase();
    return JellyfinDiscoveryAnswer(
      id: id!,
      name: _string(map['Name']),
      useTls: scheme == 'https',
      port: address != null && address.hasPort && address.port > 0 && address.port < 65536 ? address.port : null,
    );
  }
}
