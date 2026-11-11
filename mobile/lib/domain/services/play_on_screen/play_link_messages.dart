// The messages of "Play on the TV" (play_link_protocol.dart): what the phone asks the screen, and the state the screen
// tells back. The play message names the film on the screen's own access to the same server, never a token: the
// Plex machine identifier of the server and the rating key of the item. Not Plex specific beyond that: "kind" leaves
// room for an Immich asset or a file of a share later.

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// What the screen does now
enum ScreenPlayPhase {
  /// Nothing from a phone plays
  idle('idle'),

  /// The Quest asks its user before it plays
  asking('asking'),

  /// The film opens: the server is asked, the player loads
  opening('opening'),
  playing('playing'),
  paused('paused'),
  buffering('buffering'),
  ended('ended'),

  /// It did not play: [ScreenPlayState.reason] tells why
  failed('failed');

  const ScreenPlayPhase(this.wire);
  final String wire;

  static ScreenPlayPhase fromWire(Object? value) =>
      ScreenPlayPhase.values.where((phase) => phase.wire == value).firstOrNull ?? ScreenPlayPhase.idle;
}

/// Why a play did not happen, as the phone says it in one sentence
enum ScreenPlayReason {
  /// The screen has no Plex source of that machine identifier: "Add (server) to (screen)"
  noSuchServer('noSuchServer'),

  /// The screen's token for that server is refused
  tokenRefused('tokenRefused'),

  /// The server does not answer the screen
  unreachable('unreachable'),

  /// The server does not know that item
  notFound('notFound'),

  /// The user of the screen said Not now
  declined('declined'),

  /// The screen is busy (a dialog of its own, a sign in)
  busy('busy'),

  /// Anything else
  failed('failed');

  const ScreenPlayReason(this.wire);
  final String wire;

  static ScreenPlayReason? fromWire(Object? value) =>
      ScreenPlayReason.values.where((reason) => reason.wire == value).firstOrNull;
}

/// The kind of a track
enum PlayTrackKind {
  audio('audio'),
  subtitle('subtitle');

  const PlayTrackKind(this.wire);
  final String wire;

  static PlayTrackKind? fromWire(Object? value) => switch (value) {
    'audio' => PlayTrackKind.audio,
    'subtitle' => PlayTrackKind.subtitle,
    _ => null,
  };
}

/// A track of the film as the screen's player lists it
class PlayTrack {
  const PlayTrack({required this.kind, required this.id, required this.label, this.language, this.selected = false});

  final PlayTrackKind kind;

  /// The id of the screen's player, sent back as is to choose it
  final String id;
  final String label;
  final String? language;
  final bool selected;

  Map<String, Object?> toJson() => {
    'kind': kind.wire,
    'id': id,
    'label': label,
    if (language != null) 'lang': language,
    'sel': selected,
  };

  static PlayTrack? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final kind = PlayTrackKind.fromWire(json['kind']);
    final id = _shortText(json['id'], 64);
    if (kind == null || id == null) {
      return null;
    }
    return PlayTrack(
      kind: kind,
      id: id,
      label: _shortText(json['label'], 80) ?? id,
      language: _shortText(json['lang'], 16),
      selected: json['sel'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayTrack &&
      other.kind == kind &&
      other.id == id &&
      other.label == label &&
      other.language == language &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(kind, id, label, language, selected);
}

/// A choice of track the phone sends with a play: matched by language on the screen, since the ids of the two
/// players differ. [off] for subtitles off.
class PlayTrackChoice {
  const PlayTrackChoice({this.language, this.off = false});

  final String? language;
  final bool off;

  Map<String, Object?> toJson() => {if (language != null) 'lang': language, if (off) 'off': true};

  static PlayTrackChoice? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final language = _shortText(json['lang'], 16);
    final off = json['off'] == true;
    return language == null && !off ? null : PlayTrackChoice(language: language, off: off);
  }
}

/// What to play: an item of a Plex server, by the screen's own access to it
class PlayItem {
  const PlayItem({
    required this.server,
    required this.item,
    this.serverName,
    this.title,
    this.offsetMs = 0,
    this.audio,
    this.subtitle,
  });

  /// The machine identifier of the Plex server (the source's discoveryId)
  final String server;

  /// Its rating key
  final String item;

  /// For the screen's texts only: "Add (server)", the toast. Never logged.
  final String? serverName;
  final String? title;
  final int offsetMs;
  final PlayTrackChoice? audio;
  final PlayTrackChoice? subtitle;

  Map<String, Object?> toJson() => {
    'kind': 'plex',
    'server': server,
    'item': item,
    if (serverName != null) 'serverName': serverName,
    if (title != null) 'title': title,
    'offsetMs': offsetMs,
    if (audio != null) 'audio': audio!.toJson(),
    if (subtitle != null) 'subtitle': subtitle!.toJson(),
  };

  static PlayItem? fromJson(Map<String, Object?> json) {
    final server = json['server'];
    final item = json['item'];
    final offset = json['offsetMs'];
    if (json['kind'] != 'plex' ||
        server is! String ||
        !RegExp(r'^[0-9a-zA-Z]{8,64}$').hasMatch(server) ||
        item is! String ||
        !RegExp(r'^[0-9]{1,12}$').hasMatch(item)) {
      return null;
    }
    return PlayItem(
      server: server.toLowerCase(),
      item: item,
      serverName: _shortText(json['serverName'], 64),
      title: _shortText(json['title'], 160),
      offsetMs: offset is int && offset > 0 && offset < const Duration(days: 2).inMilliseconds ? offset : 0,
      audio: PlayTrackChoice.fromJson(json['audio']),
      subtitle: PlayTrackChoice.fromJson(json['subtitle']),
    );
  }

  @override
  String toString() => 'PlayItem(plex)';
}

/// What the screen tells of its playback, numbered: the phone's long poll asks for a state after the one it has
class ScreenPlayState {
  const ScreenPlayState({
    this.seq = 0,
    this.phase = ScreenPlayPhase.idle,
    this.positionMs = 0,
    this.durationMs,
    this.server,
    this.item,
    this.title,
    this.tracks = const [],
    this.reason,
    this.from,
  });

  final int seq;
  final ScreenPlayPhase phase;
  final int positionMs;
  final int? durationMs;
  final String? server;
  final String? item;
  final String? title;
  final List<PlayTrack> tracks;
  final ScreenPlayReason? reason;

  /// The name of the phone that asked for what plays
  final String? from;

  bool get isActive =>
      phase == ScreenPlayPhase.opening ||
      phase == ScreenPlayPhase.playing ||
      phase == ScreenPlayPhase.paused ||
      phase == ScreenPlayPhase.buffering;

  ScreenPlayState next({
    ScreenPlayPhase? phase,
    int? positionMs,
    int? durationMs,
    String? server,
    String? item,
    String? title,
    List<PlayTrack>? tracks,
    ScreenPlayReason? reason,
    bool clearReason = false,
    String? from,
  }) => ScreenPlayState(
    seq: seq + 1,
    phase: phase ?? this.phase,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    server: server ?? this.server,
    item: item ?? this.item,
    title: title ?? this.title,
    tracks: tracks ?? this.tracks,
    reason: clearReason ? null : (reason ?? this.reason),
    from: from ?? this.from,
  );

  /// Whether [other] says the same, its number apart
  bool sameAs(ScreenPlayState other) =>
      other.phase == phase &&
      other.positionMs == positionMs &&
      other.durationMs == durationMs &&
      other.server == server &&
      other.item == item &&
      other.title == title &&
      other.reason == reason &&
      other.from == from &&
      _sameTracks(other.tracks, tracks);

  static bool _sameTracks(List<PlayTrack> a, List<PlayTrack> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'seq': seq,
    'phase': phase.wire,
    'positionMs': positionMs,
    if (durationMs != null) 'durationMs': durationMs,
    if (server != null) 'server': server,
    if (item != null) 'item': item,
    if (title != null) 'title': title,
    if (tracks.isNotEmpty) 'tracks': [for (final track in tracks) track.toJson()],
    if (reason != null) 'reason': reason!.wire,
    if (from != null) 'from': from,
  };

  static ScreenPlayState fromJson(Object? json) {
    if (json is! Map) {
      return const ScreenPlayState();
    }
    final seq = json['seq'];
    final position = json['positionMs'];
    final duration = json['durationMs'];
    final tracks = json['tracks'];
    return ScreenPlayState(
      seq: seq is int && seq >= 0 ? seq : 0,
      phase: ScreenPlayPhase.fromWire(json['phase']),
      positionMs: position is int && position >= 0 ? position : 0,
      durationMs: duration is int && duration > 0 ? duration : null,
      server: _shortText(json['server'], 64),
      item: _shortText(json['item'], 16),
      title: _shortText(json['title'], 160),
      tracks: [
        if (tracks is List)
          for (final track in tracks.take(64)) ?PlayTrack.fromJson(track),
      ],
      reason: ScreenPlayReason.fromWire(json['reason']),
      from: _shortText(json['from'], 64),
    );
  }

  @override
  String toString() => 'ScreenPlayState($seq, ${phase.wire}${reason == null ? '' : ', ${reason!.wire}'})';
}

/// The Plex source a phone hands over with "Add (server) to (screen)": what the screen needs to connect, the token
/// apart (it travels beside it, under the keys of the handover)
class HandedPlexServer {
  const HandedPlexServer({
    required this.name,
    required this.machineIdentifier,
    required this.hash,
    required this.host,
    this.port,
    this.publicHost,
    this.publicPort,
    this.rootPath = '/',
  });

  final String name;
  final String machineIdentifier;

  /// The plex.direct hash its certificate is pinned to
  final String hash;

  /// The address at home ("" when the phone paired it from outside)
  final String host;
  final int? port;
  final String? publicHost;
  final int? publicPort;
  final String rootPath;

  Map<String, Object?> toJson() => {
    'name': name,
    'machineIdentifier': machineIdentifier,
    'hash': hash,
    'host': host,
    if (port != null) 'port': port,
    if (publicHost != null) 'publicHost': publicHost,
    if (publicPort != null) 'publicPort': publicPort,
    'rootPath': rootPath,
  };

  static HandedPlexServer? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final name = _shortText(json['name'], 64);
    final id = json['machineIdentifier'];
    final hash = json['hash'];
    final host = json['host'];
    final port = json['port'];
    final publicPort = json['publicPort'];
    final rootPath = json['rootPath'];
    if (name == null ||
        id is! String ||
        !RegExp(r'^[0-9a-zA-Z]{8,64}$').hasMatch(id) ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(hash) ||
        host is! String ||
        host.length > 253 ||
        (host.isNotEmpty && !RegExp(r'^[0-9A-Za-z.:-]+$').hasMatch(host))) {
      return null;
    }
    return HandedPlexServer(
      name: name,
      machineIdentifier: id.toLowerCase(),
      hash: hash,
      host: host,
      port: port is int && port > 0 && port < 65536 ? port : null,
      publicHost: _shortText(json['publicHost'], 253),
      publicPort: publicPort is int && publicPort > 0 && publicPort < 65536 ? publicPort : null,
      rootPath: rootPath is String && rootPath.startsWith('/') && rootPath.length < 512 ? rootPath : '/',
    );
  }

  @override
  String toString() => 'HandedPlexServer';
}

String? _shortText(Object? value, int max) {
  if (value is! String) {
    return null;
  }
  final text = cleanPairingText(value);
  if (text.isEmpty) {
    return null;
  }
  return text.length > max ? text.substring(0, max).trimRight() : text;
}
