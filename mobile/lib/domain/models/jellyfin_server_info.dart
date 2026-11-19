// What a Jellyfin or Emby server source keeps besides the fields every network source has (see
// NetworkSource.jellyfin). The token is not here: it lives in the secure storage like the password of any share, on
// this device only. The password is never kept.

final _serverId = RegExp(r'^[0-9a-f]{32}$');

/// The Jellyfin part of a network source of type jellyfin
class JellyfinServerInfo {
  const JellyfinServerInfo({
    required this.serverId,
    required this.userId,
    this.product = 'jellyfin',
    this.version,
    this.extraJson = const {},
  });

  /// The 32 lower case hex digits of the server's id (its /System/Info/Public), also the discovery id of the source:
  /// the token is only ever sent to a server that tells this id
  final String serverId;

  /// The id of the signed in user on that server
  final String userId;

  /// "jellyfin" or "emby" (see JellyfinProduct), for the names on screen and the route table
  final String product;

  /// The version of the server seen at the last sign in or open ("12.4.0", "4.10.2.0")
  final String? version;

  /// The keys of the stored object this build does not know, written back as they were. Not part of the equality.
  final Map<String, Object?> extraJson;

  static const _knownKeys = {'serverId', 'userId', 'product', 'version'};

  bool get isEmby => product == 'emby';

  /// "Jellyfin" or "Emby": a product name, never a logo
  String get productName => isEmby ? 'Emby' : 'Jellyfin';

  Map<String, Object?> toJson() => {
    ...extraJson,
    'serverId': serverId,
    'userId': userId,
    'product': product,
    if (version != null) 'version': version,
  };

  /// Null when [json] has no server id of 32 hex digits or no user id: without them the app could not tell its server
  /// from another, nor its user
  static JellyfinServerInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final serverId = json['serverId'];
    final userId = json['userId'];
    if (serverId is! String || !_serverId.hasMatch(serverId) || userId is! String || userId.isEmpty) {
      return null;
    }
    final product = json['product'];
    final version = json['version'];
    return JellyfinServerInfo(
      serverId: serverId,
      userId: userId,
      product: product == 'emby' ? 'emby' : 'jellyfin',
      version: version is String && version.isNotEmpty ? version : null,
      extraJson: Map.unmodifiable({
        for (final entry in json.entries)
          if (entry.key is String && !_knownKeys.contains(entry.key)) entry.key as String: entry.value,
      }),
    );
  }

  JellyfinServerInfo copyWith({String? userId, String? product, String? version}) => JellyfinServerInfo(
    serverId: serverId,
    userId: userId ?? this.userId,
    product: product ?? this.product,
    version: version ?? this.version,
    extraJson: extraJson,
  );

  @override
  bool operator ==(Object other) =>
      other is JellyfinServerInfo &&
      other.serverId == serverId &&
      other.userId == userId &&
      other.product == product &&
      other.version == version;

  @override
  int get hashCode => Object.hash(serverId, userId, product, version);
}
