// The kiosk mode of the Meta Quest (Settings, Advanced, "Kiosk mode", lot quest-kiosk): the 360° photo or video the
// app opens at its start for the visitors of an exhibition, and the texts the immersive viewer shows them. The need
// comes from the exhibition builds of ppawelstachh-sys/Immuch360 (branch immuch360); see KioskStart for the start and
// KioskSession on the headset for what the viewer does.

import 'dart:convert';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';

/// The media of the kiosk, as the setting keeps it ([encode], SettingsKey.kioskMedia): an asset of the device or of the
/// server ([KioskAssetMedia]) or a file of a network share ([KioskShareFile]), with its [name] for the settings and
/// whether it [isVideo]
sealed class KioskMedia {
  const KioskMedia({required this.name, required this.isVideo});

  /// [asset] as the kiosk keeps it: its id on the server and its id on the device, whichever it has, so that it is
  /// found again at the start whether the server answers or not
  factory KioskMedia.asset(BaseAsset asset) => KioskAssetMedia(
    remoteId: asset.remoteId,
    localId: asset.localId,
    name: asset.name,
    isVideo: asset.isVideo,
  );

  /// [file], a 360° file of a network share the app read (see NetworkPanoramaFile)
  factory KioskMedia.shareFile(NetworkPanoramaFile file) =>
      KioskShareFile(sourceId: file.sourceId, path: file.path, name: file.entry.name, isVideo: file.isVideo);

  final String name;
  final bool isVideo;

  Map<String, Object?> toJson();

  /// The value of the setting
  String encode() => jsonEncode(toJson());

  /// The media of the setting [json] (see [encode]); null for nothing stored or a value that does not read
  static KioskMedia? decode(String? json) {
    if (json == null || json.isEmpty) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) {
      return null;
    }
    final name = decoded['name'];
    final isVideo = decoded['isVideo'];
    if (name is! String || name.isEmpty || isVideo is! bool) {
      return null;
    }
    switch (decoded['type']) {
      case 'asset':
        final remoteId = decoded['remoteId'];
        final localId = decoded['localId'];
        final remote = remoteId is String && remoteId.isNotEmpty ? remoteId : null;
        final local = localId is String && localId.isNotEmpty ? localId : null;
        if (remote == null && local == null) {
          return null;
        }
        return KioskAssetMedia(remoteId: remote, localId: local, name: name, isVideo: isVideo);
      case 'share':
        final sourceId = decoded['sourceId'];
        final path = decoded['path'];
        if (sourceId is! String || sourceId.isEmpty || path is! String || !path.startsWith('/')) {
          return null;
        }
        return KioskShareFile(sourceId: sourceId, path: path, name: name, isVideo: isVideo);
      default:
        return null;
    }
  }
}

/// A photo or a video of the timeline: on the server ([remoteId]), on the device ([localId]), or both
final class KioskAssetMedia extends KioskMedia {
  const KioskAssetMedia({this.remoteId, this.localId, required super.name, required super.isVideo});

  final String? remoteId;
  final String? localId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'asset',
    'remoteId': ?remoteId,
    'localId': ?localId,
    'name': name,
    'isVideo': isVideo,
  };

  @override
  bool operator ==(Object other) =>
      other is KioskAssetMedia &&
      other.remoteId == remoteId &&
      other.localId == localId &&
      other.name == name &&
      other.isVideo == isVideo;

  @override
  int get hashCode => Object.hash(remoteId, localId, name, isVideo);

  @override
  String toString() => 'KioskAssetMedia(remote: $remoteId, local: $localId, $name, video: $isVideo)';
}

/// A file of a network share, at [path] of the share [sourceId]
final class KioskShareFile extends KioskMedia {
  const KioskShareFile({required this.sourceId, required this.path, required super.name, required super.isVideo});

  final String sourceId;

  /// Absolute inside the share, "/" separated, starting with "/"
  final String path;

  @override
  Map<String, Object?> toJson() => {
    'type': 'share',
    'sourceId': sourceId,
    'path': path,
    'name': name,
    'isVideo': isVideo,
  };

  @override
  bool operator ==(Object other) =>
      other is KioskShareFile &&
      other.sourceId == sourceId &&
      other.path == path &&
      other.name == name &&
      other.isVideo == isVideo;

  @override
  int get hashCode => Object.hash(sourceId, path, name, isVideo);

  @override
  String toString() => 'KioskShareFile($sourceId, $path, video: $isVideo)';
}

/// What the immersive viewer of a kiosk opening is told, in the language of the app (the kiosk JSON of
/// ImmersiveApi.open, read by KioskOptions on the headset): [endText] on the card at the end of the film, [exitHint]
/// passing at the start to say how to leave
class KioskOptions {
  const KioskOptions({required this.endText, required this.exitHint});

  final String endText;
  final String exitHint;

  String toJson() => jsonEncode({'endText': endText, 'exitHint': exitHint});

  @override
  bool operator ==(Object other) => other is KioskOptions && other.endText == endText && other.exitHint == exitHint;

  @override
  int get hashCode => Object.hash(endText, exitHint);
}
