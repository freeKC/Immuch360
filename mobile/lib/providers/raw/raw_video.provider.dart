// The raw 360° videos as the viewers open them (see RawVideoResolver): which layouts of two streams the native players
// of this platform play, the input of an asset or of a file of a share, and where the other file of a split Insta360
// pair is found: on the device next to it, on the server among the videos of the same owner, or in the same folder of
// the share.

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/raw/dual_fisheye.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('RawVideo');

/// Whether the native player of each platform plays the raw videos of two streams (two tracks of one file, the two
/// files of a split pair, the GoPro EAC tracks): the Android phone player (SphericalVideoActivity), the immersive
/// viewer of the Meta Quest (ImmersiveViewerActivity), the iOS player (SphericalVideoViewController). All three land
/// in build 18; a player that turns out not to may be switched off here, its raw videos of two streams then saying
/// they do not open rather than showing one lens as both.
const rawTwoStreamPlayback = (android: true, quest: true, ios: true);

/// Which layouts of two streams the players of this device play (see [rawTwoStreamPlayback])
final rawVideoPlaybackSupportProvider = Provider<RawVideoPlaybackSupport>((ref) {
  final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
  return RawVideoPlaybackSupport(
    twoStreams: Platform.isIOS
        ? rawTwoStreamPlayback.ios
        : Platform.isAndroid && (isHorizonOs ? rawTwoStreamPlayback.quest : rawTwoStreamPlayback.android),
  );
});

/// Settles how the raw videos open (see [RawVideoResolver.resolve])
final rawVideoResolverProvider = Provider<RawVideoResolver>(
  (ref) => RawVideoResolver(
    calibrations: ref.watch(dualFisheyeCalibrationServiceProvider),
    support: ref.watch(rawVideoPlaybackSupportProvider),
  ),
);

/// The inputs of the raw videos of the library, and their siblings (see [RawAssetInputs]). The database is only asked
/// for when a split pair looks for its other file: every opening of a 360° video reads this provider.
final rawAssetInputsProvider = Provider<RawAssetInputs>(
  (ref) => RawAssetInputs(
    local: () => ref.read(driftProvider).localAssetRepository,
    remote: () => ref.read(driftProvider).remoteAssetRepository,
    storage: ref.watch(storageRepositoryProvider),
    probes: ref.watch(sphericalProbeServiceProvider),
    calibrations: ref.watch(dualFisheyeCalibrationServiceProvider),
  ),
);

/// Why the raw video of [error] does not open in 360°, in the words of [t]: the other file of its split pair is not
/// found next to it, or the app cannot stitch its layout on this device
String rawVideoUnsupportedMessage(Translations t, RawVideoUnsupportedException error) => switch (error.reason) {
  RawUnsupportedReason.siblingMissing => t.raw_video_sibling_missing(name: error.siblingName ?? error.name),
  RawUnsupportedReason.unknownLayout => t.raw_video_layout_unsupported,
};

/// Translated messages of the native 360° players about raw videos, under the keys they read: "rawHeavy" when the
/// decoders of the device may not keep up with the two streams of a raw video; when the player falls back,
/// "rawOneLensDecoder" for one lens shown because the decoders refused two, "rawOneLensFile" for one lens shown because
/// the file of the other could not be read, and "rawUnstitched" for the frames shown as the camera recorded them.
/// "{codec}", "{width}" and "{height}" are left for the players to fill in from the track.
Map<String, String> rawVideoLabels(Translations t) => {
  'rawHeavy': t.raw_video_two_decoders_heavy(size: '{width}x{height}'),
  'rawOneLensDecoder': t.raw_video_one_lens_decoder(codec: '{codec}', width: '{width}', height: '{height}'),
  'rawOneLensFile': t.raw_video_one_lens_file,
  'rawUnstitched': t.raw_video_unstitched,
};

/// The key of the calibration of [entry], a file of a share: its path, its size and its date tell it from any other
String rawShareKey(NetworkEntry entry) =>
    'share:${entry.sourceId}:${entry.path}:${entry.size}:${entry.modified?.millisecondsSinceEpoch}';

/// The raw videos of the library as the resolver reads them: the input of an asset (see [input]) and the finder of
/// the other file of its split pair (see [siblings])
class RawAssetInputs {
  RawAssetInputs({
    required this._local,
    required this._remote,
    required this._storage,
    required this._probes,
    required this._calibrations,
    this._originalUrl = serverOriginalVideoUrl,
    this._transcodedUrl = serverTranscodedVideoUrl,
  });

  // The repositories of the database, asked for when a sibling is looked for
  final LocalAssetRepository Function() _local;
  final RemoteAssetRepository Function() _remote;
  final StorageRepository _storage;
  final SphericalProbeService _probes;
  final DualFisheyeCalibrationService _calibrations;
  final String Function(String videoId) _originalUrl;
  final String Function(String videoId) _transcodedUrl;

  /// The input of [asset] played from [source]: its file on the device ([localFile]), or the server URL the policy
  /// chose, with the original besides when that is its transcoded stream. Its calibration is read from the file
  /// itself: [localFile], else the copy on the device, else the original on the server. [probe] is what its file
  /// declares, when read already.
  RawVideoInput input(BaseAsset asset, {File? localFile, required ChosenVideoSource source, SphericalProbe? probe}) {
    final remoteId = asset.remoteId;
    final original = localFile == null && remoteId != null ? _originalUrl(remoteId) : null;
    return RawVideoInput(
      name: asset.name,
      key: rawAssetKey(asset),
      url: source.url,
      originalUrl: original != null && source.url != original ? original : null,
      fallbackUrl: source.fallbackUrl,
      open: () => _calibrations.openAsset(asset, localFile: localFile),
      probe: probe,
      width: asset.width,
      height: asset.height,
    );
  }

  /// The finder of the other file of the split pair of [asset], played from [source]: on the device first when
  /// [asset] plays from there ([localFile]), else, or when it is not found there, on the server, its original when
  /// [asset] plays its original or its file on the device, else its transcoded stream, with its transcoded stream as
  /// fallback when [source] has one
  RawSiblingFinder siblings(BaseAsset asset, {File? localFile, required ChosenVideoSource source}) =>
      (siblingName) async =>
          await _onDevice(asset, siblingName, fromDevice: localFile != null) ??
          await _onServer(asset, siblingName, source: source, fromDevice: localFile != null);

  Future<RawVideoInput?> _onDevice(BaseAsset asset, String siblingName, {required bool fromDevice}) async {
    final localId = asset.localId;
    if (!fromDevice || localId == null) {
      return null;
    }
    try {
      final sibling = await _local().findSiblingByName(localId, siblingName);
      if (sibling == null) {
        _log.info('${asset.name}: no $siblingName on the device next to it');
        return null;
      }
      final file = await _storage.getFileForAsset(sibling.id);
      if (file == null) {
        _log.info('${asset.name}: $siblingName is on the device, but its file is not');
        return null;
      }
      return RawVideoInput(
        name: sibling.name,
        key: rawAssetKey(sibling),
        url: file.uri.toString(),
        open: () => _calibrations.openAsset(sibling, localFile: file),
        probe: await _probes.probe(sibling, localFile: file),
        width: sibling.width,
        height: sibling.height,
      );
    } catch (error) {
      _log.info('${asset.name}: could not look for $siblingName on the device: $error');
      return null;
    }
  }

  Future<RawVideoInput?> _onServer(
    BaseAsset asset,
    String siblingName, {
    required ChosenVideoSource source,
    required bool fromDevice,
  }) async {
    final remoteId = asset.remoteId;
    if (remoteId == null) {
      return null;
    }
    try {
      final sibling = await _remote().findSiblingByName(remoteId, siblingName);
      if (sibling == null) {
        _log.info('${asset.name}: no $siblingName on the server');
        return null;
      }
      final original = _originalUrl(sibling.id);
      // The same choice as the opened file: both originals, or both transcoded streams; a file of the device pairs
      // with the original
      final playsOriginal = fromDevice || source.url == _originalUrl(remoteId);
      return RawVideoInput(
        name: sibling.name,
        key: rawAssetKey(sibling),
        url: playsOriginal ? original : _transcodedUrl(sibling.id),
        originalUrl: playsOriginal ? null : original,
        fallbackUrl: source.fallbackUrl != null ? _transcodedUrl(sibling.id) : null,
        open: () => _calibrations.openAsset(sibling),
        probe: await _probes.probe(sibling),
        width: sibling.width,
        height: sibling.height,
      );
    } catch (error) {
      _log.info('${asset.name}: could not look for $siblingName on the server: $error');
      return null;
    }
  }
}

/// A file of a share and its media bridge URL
typedef ShareMediaItem = ({NetworkEntry entry, Uri url});

/// How long the listing of a folder of a share may take when the other file of a pair is looked for there
const rawShareSiblingListTimeout = Duration(seconds: 10);

/// The finder of the other file of the split pair of [entry], a raw video of a share: in [folder], the listing of the
/// page when it has one, by its name, else by its name case aside; else in a fresh listing of its folder through
/// [connections] when given, within [rawShareSiblingListTimeout]. The file found is read through the media bridge with
/// [bridgeClient], its probe through [media].
RawSiblingFinder shareSiblingFinder({
  required NetworkEntry entry,
  List<ShareMediaItem>? folder,
  required NetworkConnections? connections,
  required http.Client bridgeClient,
  required NetworkMediaService media,
}) => (siblingName) async {
  var found = _named(folder ?? const [], siblingName);
  if (found == null && connections != null) {
    try {
      final fileSystem = await connections.fileSystem(entry.sourceId);
      final listed = await fileSystem.list(_parentOf(entry.path)).timeout(rawShareSiblingListTimeout);
      final sibling = _named([for (final item in listed) (entry: item, url: Uri())], siblingName)?.entry;
      if (sibling != null) {
        found = (entry: sibling, url: await connections.mediaUrl(entry.sourceId, sibling.path));
      }
    } on TimeoutException {
      _log.info('${entry.name}: listing its folder for $siblingName timed out');
    } catch (error) {
      _log.info('${entry.name}: could not list its folder for $siblingName: $error');
    }
  }
  if (found == null) {
    _log.info('${entry.name}: no $siblingName next to it');
    return null;
  }
  final (entry: sibling, :url) = found;
  final read = httpRangeReader(bridgeClient, url);
  NetworkMediaInfo? info;
  try {
    info = await media.detect(sibling, read, thorough: true);
  } catch (error) {
    _log.info('${sibling.name}: could not read what it declares: $error');
  }
  return RawVideoInput(
    name: sibling.name,
    key: rawShareKey(sibling),
    url: url.toString(),
    open: () async => (size: sibling.size, read: read, close: () async {}),
    probe: info?.probe,
  );
};

// The file of [items] named [name], else named so case aside, which a share on a case insensitive file system may
// change; files only
ShareMediaItem? _named(List<ShareMediaItem> items, String name) {
  final files = items.where((item) => !item.entry.isDirectory);
  final lower = name.toLowerCase();
  return files.firstWhereOrNull((item) => item.entry.name == name) ??
      files.firstWhereOrNull((item) => item.entry.name.toLowerCase() == lower);
}

// The folder of the file at [path] ("/a/b.insv" gives "/a", "/b.insv" gives "/")
String _parentOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}
