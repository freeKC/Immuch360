// What a Plex Media Server source keeps besides the fields every network source has (see NetworkSource.plex). The
// token is not here: it lives in the secure storage like the password of any share.

/// The 32 lower case hex digits of the plex.direct certificate of a server
final _plexHash = RegExp(r'^[0-9a-f]{32}$');

/// The Plex part of a network source of type plex
class PlexServerInfo {
  const PlexServerInfo({required this.hash, this.publicHost, this.publicPort, this.version, this.extraJson = const {}});

  /// The 32 lower case hex digits of `*.<hash>.plex.direct`: the only server the token is ever sent to is the one that
  /// holds the certificate of this name
  final String hash;

  /// Address outside home typed by the user: an IPv4 address or a host name (DynDNS); null when none
  final String? publicHost;
  final int? publicPort;

  /// Plex Media Server version seen by the edit page
  final String? version;

  /// The keys of the stored object this build does not know, written back as they were so that the later build that
  /// wrote them finds them again. Not part of the equality.
  final Map<String, Object?> extraJson;

  static const _knownKeys = {'hash', 'publicHost', 'publicPort', 'version'};

  Map<String, Object?> toJson() => {
    ...extraJson,
    'hash': hash,
    if (publicHost != null) 'publicHost': publicHost,
    if (publicPort != null) 'publicPort': publicPort,
    if (version != null) 'version': version,
  };

  /// Null when [json] has no hash matching ^[0-9a-f]{32}$: without it the app could not tell its server from another
  static PlexServerInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final hash = json['hash'];
    if (hash is! String || !_plexHash.hasMatch(hash)) {
      return null;
    }
    final publicHost = json['publicHost'];
    final publicPort = json['publicPort'];
    final version = json['version'];
    return PlexServerInfo(
      hash: hash,
      publicHost: publicHost is String && publicHost.isNotEmpty ? publicHost : null,
      publicPort: publicPort is int && publicPort > 0 && publicPort < 65536 ? publicPort : null,
      version: version is String && version.isNotEmpty ? version : null,
      extraJson: Map.unmodifiable({
        for (final entry in json.entries)
          if (entry.key is String && !_knownKeys.contains(entry.key)) entry.key as String: entry.value,
      }),
    );
  }

  PlexServerInfo copyWith({
    String? publicHost,
    bool clearPublicHost = false,
    int? publicPort,
    bool clearPublicPort = false,
    String? version,
  }) => PlexServerInfo(
    hash: hash,
    publicHost: clearPublicHost ? null : (publicHost ?? this.publicHost),
    publicPort: clearPublicPort ? null : (publicPort ?? this.publicPort),
    version: version ?? this.version,
    extraJson: extraJson,
  );

  @override
  bool operator ==(Object other) =>
      other is PlexServerInfo &&
      other.hash == hash &&
      other.publicHost == publicHost &&
      other.publicPort == publicPort &&
      other.version == version;

  @override
  int get hashCode => Object.hash(hash, publicHost, publicPort, version);
}
