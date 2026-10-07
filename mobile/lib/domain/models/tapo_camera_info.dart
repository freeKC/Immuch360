// What the app learned about a Tapo camera (see NetworkSource.camera): its model, how its login went, the certificate
// it showed the first time. Nothing secret: the passwords live in the secure storage like the password of any share.

/// The login generation of a camera
enum TapoLoginProtocol { v2, v3, v4 }

/// Which form of the TP-Link password the camera accepted
enum TapoPasscodeHash { md5, sha256 }

/// The form of the user name a V4 login accepted
enum TapoUserNameForm { md5, sha256, plain }

/// What the app learned about a camera; nothing secret in it
class TapoCameraInfo {
  const TapoCameraInfo({
    this.model,
    this.firmware,
    this.protocol,
    this.passcode,
    this.userName,
    this.zoneId,
    this.rtspPort = defaultRtspPort,
    this.mediaPort = defaultMediaPort,
    this.certificateSha256,
    this.extraJson = const {},
  });

  static const defaultRtspPort = 554;
  static const defaultMediaPort = 8800;

  final String? model;
  final String? firmware;
  final TapoLoginProtocol? protocol;

  /// Which passcode form the camera accepted, null before the first login
  final TapoPasscodeHash? passcode;

  /// The V4 user name form that worked
  final TapoUserNameForm? userName;

  /// The camera's time zone (getTimezone zone_id), for the day bounds
  final String? zoneId;
  final int rtspPort;
  final int mediaPort;

  /// Lower case hex SHA-256 of the camera's DER certificate, seen at the first login (trust on first use)
  final String? certificateSha256;

  /// What a later build stored and this one does not know: the keys it does not know, and the values of its own keys
  /// that it cannot read (an enum value added later). Written back as they were, so that the later build finds them
  /// again; a value this build learns replaces them. Not part of the equality.
  final Map<String, Object?> extraJson;

  static const _knownKeys = {
    'model',
    'firmware',
    'protocol',
    'passcode',
    'userName',
    'zoneId',
    'rtspPort',
    'mediaPort',
    'certificateSha256',
  };

  Map<String, Object?> toJson() => {
    ...extraJson,
    if (model != null) 'model': model,
    if (firmware != null) 'firmware': firmware,
    if (protocol != null) 'protocol': protocol!.name,
    if (passcode != null) 'passcode': passcode!.name,
    if (userName != null) 'userName': userName!.name,
    if (zoneId != null) 'zoneId': zoneId,
    'rtspPort': rtspPort,
    'mediaPort': mediaPort,
    if (certificateSha256 != null) 'certificateSha256': certificateSha256,
  };

  /// Enum values stored by a later build and unknown here read as null (and are kept in [extraJson]); anything that is
  /// not a map reads as an empty info
  static TapoCameraInfo fromJson(Object? json) {
    if (json is! Map) {
      return const TapoCameraInfo();
    }
    final extra = <String, Object?>{};
    for (final entry in json.entries) {
      final key = entry.key;
      if (key is String && !_knownKeys.contains(key)) {
        extra[key] = entry.value;
      }
    }

    T? enumValue<T extends Enum>(String key, List<T> values) {
      final stored = json[key];
      if (stored == null) {
        return null;
      }
      final value = values.where((v) => v.name == stored).firstOrNull;
      if (value == null) {
        extra[key] = stored;
      }
      return value;
    }

    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    int port(String key, int fallback) {
      final value = json[key];
      return value is int && value > 0 && value < 65536 ? value : fallback;
    }

    return TapoCameraInfo(
      model: text('model'),
      firmware: text('firmware'),
      protocol: enumValue('protocol', TapoLoginProtocol.values),
      passcode: enumValue('passcode', TapoPasscodeHash.values),
      userName: enumValue('userName', TapoUserNameForm.values),
      zoneId: text('zoneId'),
      rtspPort: port('rtspPort', defaultRtspPort),
      mediaPort: port('mediaPort', defaultMediaPort),
      // Kept as stored even when it does not read as a digest: such a pin matches no certificate, so the user is asked
      // rather than the first certificate seen being trusted again
      certificateSha256: text('certificateSha256'),
      extraJson: Map.unmodifiable(extra),
    );
  }

  TapoCameraInfo copyWith({
    String? model,
    String? firmware,
    TapoLoginProtocol? protocol,
    TapoPasscodeHash? passcode,
    TapoUserNameForm? userName,
    String? zoneId,
    int? rtspPort,
    int? mediaPort,
    String? certificateSha256,
  }) => TapoCameraInfo(
    model: model ?? this.model,
    firmware: firmware ?? this.firmware,
    protocol: protocol ?? this.protocol,
    passcode: passcode ?? this.passcode,
    userName: userName ?? this.userName,
    zoneId: zoneId ?? this.zoneId,
    rtspPort: rtspPort ?? this.rtspPort,
    mediaPort: mediaPort ?? this.mediaPort,
    certificateSha256: certificateSha256 ?? this.certificateSha256,
    extraJson: extraJson,
  );

  @override
  bool operator ==(Object other) =>
      other is TapoCameraInfo &&
      other.model == model &&
      other.firmware == firmware &&
      other.protocol == protocol &&
      other.passcode == passcode &&
      other.userName == userName &&
      other.zoneId == zoneId &&
      other.rtspPort == rtspPort &&
      other.mediaPort == mediaPort &&
      other.certificateSha256 == certificateSha256;

  @override
  int get hashCode =>
      Object.hash(model, firmware, protocol, passcode, userName, zoneId, rtspPort, mediaPort, certificateSha256);

  @override
  String toString() =>
      'TapoCameraInfo(${model ?? '?'} ${firmware ?? '?'} ${protocol?.name ?? '?'}'
      '${certificateSha256 == null ? '' : ' pinned'})';
}
