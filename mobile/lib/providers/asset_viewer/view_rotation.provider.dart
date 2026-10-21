// The one-key rotation of the viewers (see view_rotation.dart): which photos turn and how ([rotationModeProvider]),
// the turns kept on this device ([ViewRotations]), the turns sent to the server ([ViewRotationController]), and what
// the viewer draws ([displayQuarterTurnsProvider]).
//
// The 360°, 180° and 3D views never turn: they turn their camera instead, and follow the head or the phone by
// themselves. Every rule that makes the app show an asset in one of them makes it mode none, and so does a rule the
// app cannot settle yet (the exif still loading, a file of the device not read yet): no button, no key, no stored
// turn, no request. Those views read neither the turns kept here nor the server's edits: they ask for the unedited
// files (see panoramaImageProvider and immersiveMediaUrl), and guess their layout from the size of those files, never
// from the size an edit gave the asset (see uneditedFrameOf).

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/server_capability.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/unedited_frame.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/edit_asset.action.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:immich_mobile/utils/editor.utils.dart';
import 'package:logging/logging.dart';

final _log = Logger('ViewRotation');

/// How a photo turns with the one-key rotation
enum RotationMode {
  /// It does not: a video, an asset in the trash, any 360°, 180° or 3D photo, or one whose kind the app cannot tell yet
  none,

  /// On the server, as an edit, seen everywhere: an Immich photo of the user that the server can edit
  server,

  /// On this device only, remembered per photo (see [ViewRotations])
  device,
}

// The pictures the server refuses to edit, besides videos, live photos, animations and panoramas
bool _isServerEditableName(String name) {
  final lower = name.toLowerCase();
  return !lower.endsWith('.gif') && !lower.endsWith('.svg');
}

/// An asset as the rotation mode sees it: equal for two copies of an asset that differ only in what the mode does not
/// read (favourite, dates, thumbhash, size after an edit...). The viewer gets a new copy of its asset at each change of
/// it; keyed by this, the mode of the new copy is the one already known, never "not known yet" for a frame, which
/// would turn the photo back and forth on screen.
@immutable
class RotationSubject {
  const RotationSubject(this.asset);

  final BaseAsset asset;

  Object get _identity {
    final asset = this.asset;
    return (
      asset.runtimeType,
      asset.id,
      asset.remoteId,
      asset.localId,
      asset.name,
      asset.type,
      asset.isEditable,
      asset is RemoteAsset ? (asset.ownerId, asset.isTrashed, asset.isLocked) : null,
    );
  }

  @override
  bool operator ==(Object other) => other is RotationSubject && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;
}

/// How [asset] turns with the one-key rotation, see [RotationMode] and [rotationModeFamily]
AutoDisposeProvider<RotationMode> rotationModeProvider(BaseAsset asset) => rotationModeFamily(RotationSubject(asset));

/// How an asset turns with the one-key rotation, see [RotationMode].
///
/// None for anything but a photo, for an asset in the trash or in the locked folder (where the editor is not offered
/// either), and for every photo the app shows in 360°, 180° or 3D: the user chose "View as 360°" for it, its exif
/// declares an equirectangular projection, a 360° camera stitched it (the camera rule), it is a 2:1 photo of an
/// Insta360 camera, its file on the device was found 360° or raw, its name is that of a raw file of a 360° camera, or
/// it is an Apple spatial photo. None too while that cannot be told yet: the exif of an asset of the server still
/// loading or missing, a file of the device that may be 360° and was not read yet, a HEIF photo whose stereo pair is
/// still being looked for or could not be read.
///
/// The shapes are those of the files ([uneditedFrameOf]), never the size an edit of the server gave the asset: a 1:2
/// photo turned once on the server is no 2:1 one that may be 360°.
///
/// Server for a photo of the user on a server that takes edits (2.6.0 and later), unless the read only mode is on, or
/// the server refuses its format. Device for any other flat photo: a photo of the device only, of a partner, of a
/// shared album, on an older server, a motion photo, an animation.
final rotationModeFamily = Provider.autoDispose.family<RotationMode, RotationSubject>((ref, subject) {
  final asset = subject.asset;
  if (!asset.isImage || (asset is RemoteAsset && (asset.isTrashed || asset.isLocked))) {
    return RotationMode.none;
  }
  if (ref.watch(rawMediaKindProvider(asset)) != null ||
      ref.watch(isForcedPanoramaProvider(asset)) ||
      ref.watch(isFoundLocalPanoramaProvider(asset))) {
    return RotationMode.none;
  }
  AssetFrame? fileFrame;
  if (asset.hasRemote) {
    final exif = ref.watch(
      assetExifProvider(asset).select((state) {
        final exif = state.valueOrNull;
        return exif == null
            ? null
            : (make: exif.make, size: (width: exif.width, height: exif.height), file: uneditedFrameOf(asset, exif));
      }),
    );
    if (exif == null || ref.watch(hasEquirectangularExifProvider(asset))) {
      return RotationMode.none;
    }
    if (_isInsta360Sphere(exif.make, isKnownFrame(exif.size) ? exif.size : exif.file)) {
      return RotationMode.none;
    }
    if (isKnownFrame(exif.file)) {
      fileFrame = exif.file;
    }
  }
  if (ref.watch(hasEquirectCameraExifProvider(asset))) {
    return RotationMode.none;
  }
  final localId = asset.localId;
  if (localId != null &&
      isLocalPanoramaCandidate(asset, frame: fileFrame) &&
      !ref.watch(localPanoramaAssetsProvider.select((records) => records.containsKey(localId))) &&
      !ref.watch(openedFilePanoramasProvider.select((records) => records.containsKey(localId)))) {
    return RotationMode.none;
  }
  if (isHeifName(asset.name)) {
    final spatial = ref.watch(appleSpatialInfoProvider(asset));
    // A check that failed tells nothing: the photo may hold two eyes
    if ((spatial.isLoading && !spatial.hasValue) || spatial.hasError || spatial.valueOrNull?.photo != null) {
      return RotationMode.none;
    }
  }
  if (asset is RemoteAsset && asset.isEditable && _isServerEditableName(asset.name)) {
    final takesEdits = ref.watch(
      serverInfoProvider.select((info) => info.serverVersion.supports(ServerCapability.syncAssetEditsV1)),
    );
    final userId = ref.watch(currentUserProvider.select((user) => user?.id));
    if (takesEdits && userId != null && asset.ownerId == userId && !ref.watch(readonlyModeProvider)) {
      return RotationMode.server;
    }
  }
  return RotationMode.device;
});

/// Whether [make] and [frame] are those of a 360° photo of an Insta360 camera: 2:1 (or 1:2), or of a size not known.
/// Raw dual fisheye renamed .jpg or stitched by the camera, the exif of the server cannot tell them apart, so the
/// viewers leave both flat until the user views them as 360° (see hasEquirectCameraExifProvider), but the 360° page
/// lists them and the Meta Quest shows them on the sphere: never turned. The other photos of the brand (its action
/// cameras) turn.
bool _isInsta360Sphere(String? make, AssetFrame frame) {
  if (make?.trim().toLowerCase() != 'arashi vision') {
    return false;
  }
  if (!isKnownFrame(frame)) {
    return true;
  }
  final width = frame.width!;
  final height = frame.height!;
  return (math.max(width, height) / math.min(width, height) / 2 - 1).abs() <= 0.02;
}

/// The turns kept on this device, per asset of the library and per file of a share (see [ViewRotationEntry]), stored
/// in [StoreKey.viewRotations]. A share removed takes its files along, even while nothing read them; the assets gone
/// from the database are dropped once per run, at a rotation, once the database can tell (see [_pruneOnce]).
class ViewRotations extends Notifier<Map<String, ViewRotationEntry>> {
  ViewRotations({this.maxEntries = maxViewRotations});

  /// Past this many photos, the ones turned first are forgotten
  final int maxEntries;

  static bool _prunedThisRun = false;

  @visibleForTesting
  static void resetPrune() => _prunedThisRun = false;

  @override
  Map<String, ViewRotationEntry> build() {
    ref.listen(networkSourcesProvider, (_, sources) => _keepSourcesOf(sources));
    final Map<String, ViewRotationEntry> stored;
    try {
      stored = decodeViewRotations(ref.watch(storeServiceProvider).tryGet(StoreKey.viewRotations));
    } on UnsupportedError catch (error) {
      // The store is not initialised: nothing was turned yet, and a viewer must not fail for that
      _log.fine('No store for the rotations: $error');
      return const {};
    }
    final kept = _withoutSharesGone(stored, ref.read(networkSourcesProvider));
    if (kept.length != stored.length) {
      // Removed while nothing read the rotations
      unawaited(_write(kept));
    }
    return UnmodifiableMapView(kept);
  }

  /// The quarter turns kept for [asset], 0 when none
  int assetTurns(BaseAsset asset) => viewRotationTurnsOf(state, asset);

  /// Keeps [turns] quarter turns for [asset] (0 forgets it), an asset of the server with the user signed in. A
  /// rotation chosen before the upload, under the id on the device, moves under the server id.
  Future<void> setAssetTurns(BaseAsset asset, int turns) async {
    final key = viewRotationAssetKey(asset);
    final localKey = viewRotationLocalKey(asset);
    final normalized = normalizeQuarterTurns(turns);
    final userId = asset is RemoteAsset ? ref.read(currentUserProvider)?.id : null;
    var next = withViewRotation(
      state,
      key,
      normalized == 0 ? null : ViewRotationEntry(normalized, userId: userId),
      maxEntries: maxEntries,
    );
    if (localKey != null && localKey != key) {
      next = withViewRotation(next, localKey, null, maxEntries: maxEntries);
    }
    await _save(next);
  }

  /// Turns [asset] by [delta] more quarter turns clockwise
  Future<void> rotateAsset(BaseAsset asset, int delta) => setAssetTurns(asset, assetTurns(asset) + delta);

  /// The quarter turns kept for the file at [path] of the share [sourceId], of [size] bytes modified at
  /// [modifiedMs]: 0 when none, or when they were kept for another file under that path
  int shareTurns(String sourceId, String path, {int? size, int? modifiedMs}) =>
      viewRotationShareTurnsOf(state, sourceId, path, size: size, modifiedMs: modifiedMs);

  /// Turns the file at [path] of the share [sourceId] by [delta] more quarter turns clockwise
  Future<void> rotateShare(String sourceId, String path, int delta, {int? size, int? modifiedMs}) async {
    final turns = normalizeQuarterTurns(shareTurns(sourceId, path, size: size, modifiedMs: modifiedMs) + delta);
    await _save(
      withViewRotation(
        state,
        viewRotationShareKey(sourceId, path),
        turns == 0 ? null : ViewRotationEntry(turns, size: size, modifiedMs: modifiedMs),
        maxEntries: maxEntries,
      ),
    );
  }

  void _keepSourcesOf(List<NetworkSource> sources) {
    final kept = _withoutSharesGone(state, sources);
    if (kept.length == state.length) {
      return;
    }
    unawaited(_save(kept));
  }

  // [entries] without the files of the shares that are not among [sources]
  static Map<String, ViewRotationEntry> _withoutSharesGone(
    Map<String, ViewRotationEntry> entries,
    List<NetworkSource> sources,
  ) {
    final ids = {for (final source in sources) source.id};
    bool isGone(String key) => key.startsWith('n:') && !ids.any((id) => isViewRotationShareKeyOf(key, id));
    return entries.keys.any(isGone) ? ({...entries}..removeWhere((key, _) => isGone(key))) : entries;
  }

  /// Drops the rotations of the assets that are no longer in the database (their ids are never used again), once per
  /// run, as soon as the database can tell: signed in, with a sync of the server finished in this run and none
  /// running, so that an asset not synced yet after a sign in is not taken for one gone. Only the files of this device
  /// and the assets turned under the user signed in are checked: those turned under another account (another server,
  /// another user) wait for it. Not on a computer, whose files opened with the program are no assets of the database,
  /// nor while the database holds no asset of the server.
  Future<void> _pruneOnce() async {
    if (_prunedThisRun || CurrentPlatform.isDesktop || !state.keys.any((key) => viewRotationAssetId(key) != null)) {
      return;
    }
    try {
      if (ref.read(syncStatusProvider).remoteSyncStatus != SyncStatus.success) {
        // Tried again at the next rotation
        return;
      }
      final userId = ref.read(currentUserProvider)?.id;
      if (userId == null) {
        return;
      }
      final ids = {
        for (final MapEntry(:key, :value) in state.entries)
          if (value.userId == null || value.userId == userId) ?viewRotationAssetId(key),
      };
      if (ids.isEmpty) {
        return;
      }
      _prunedThisRun = true;
      final existing = await ref.read(viewRotationAssetIdsProvider)(ids);
      if (existing == null) {
        return;
      }
      final gone = ids.difference(existing);
      if (gone.isEmpty) {
        return;
      }
      _log.fine('Forgetting the rotations of ${gone.length} assets no longer in the library');
      await _save({...state}..removeWhere((key, _) => gone.contains(viewRotationAssetId(key))));
    } catch (error, stackTrace) {
      _log.warning('Could not check the turned assets against the library', error, stackTrace);
    }
  }

  Future<void> _save(Map<String, ViewRotationEntry> entries) async {
    state = UnmodifiableMapView(entries);
    await _write(entries);
    unawaited(_pruneOnce());
  }

  Future<void> _write(Map<String, ViewRotationEntry> entries) async {
    try {
      final store = ref.read(storeServiceProvider);
      if (entries.isEmpty) {
        await store.delete(StoreKey.viewRotations);
      } else {
        await store.put(StoreKey.viewRotations, encodeViewRotations(entries));
      }
    } catch (error, stackTrace) {
      // The rotation still holds until the app restarts
      _log.warning('Could not remember the rotations', error, stackTrace);
    }
  }
}

/// The quarter turns [entries] keep for [asset]: under its own key (see [viewRotationAssetKey]); else, for an asset
/// of the server whose picture carries no edit, those chosen for its file on the device before the upload, the same
/// picture then. Once the server edited it, its picture is no longer the file those turns were chosen for.
int viewRotationTurnsOf(Map<String, ViewRotationEntry> entries, BaseAsset asset) {
  final own = entries[viewRotationAssetKey(asset)];
  if (own != null) {
    return own.turns;
  }
  final localKey = viewRotationLocalKey(asset);
  if (localKey == null || (asset is RemoteAsset && asset.isEdited)) {
    return 0;
  }
  return entries[localKey]?.turns ?? 0;
}

final viewRotationsProvider = NotifierProvider<ViewRotations, Map<String, ViewRotationEntry>>(ViewRotations.new);

/// Which of the given asset ids the database holds, on the server or on the device; null when it holds no asset of a
/// server, and cannot tell. Tests replace it.
final viewRotationAssetIdsProvider = Provider<Future<Set<String>?> Function(Set<String> ids)>(
  (ref) =>
      (ids) => existingAssetIds(ref.read(driftProvider), ids),
);

/// The ids among [ids] of the assets [db] holds, see [viewRotationAssetIdsProvider]
Future<Set<String>?> existingAssetIds(Drift db, Set<String> ids) async {
  final remoteCount = await db.managers.remoteAssetEntity.count();
  if (remoteCount == 0) {
    return null;
  }
  final found = <String>{};
  final list = ids.toList(growable: false);
  for (var start = 0; start < list.length; start += 500) {
    final chunk = list.sublist(start, math.min(start + 500, list.length));
    final remote = db.selectOnly(db.remoteAssetEntity)
      ..addColumns([db.remoteAssetEntity.id])
      ..where(db.remoteAssetEntity.id.isIn(chunk));
    final local = db.selectOnly(db.localAssetEntity)
      ..addColumns([db.localAssetEntity.id])
      ..where(db.localAssetEntity.id.isIn(chunk));
    found
      ..addAll(await remote.map((row) => row.read(db.remoteAssetEntity.id)!).get())
      ..addAll(await local.map((row) => row.read(db.localAssetEntity.id)!).get());
  }
  return found;
}

/// What the server side of the rotation needs: the edits of an asset as the database holds them, whether it holds
/// edits of a kind the app does not know, and the request that replaces them (see [applyAssetEdits]), which gives the
/// new thumbhash once the server made the edited files, null when it did not say in time. Tests replace it.
class ViewRotationServer {
  const ViewRotationServer({required this.edits, required this.hasUnknownEdits, required this.apply});

  final Future<List<AssetEdit>> Function(String remoteId) edits;
  final Future<bool> Function(String remoteId) hasUnknownEdits;
  final Future<String?> Function(String remoteId, List<AssetEdit> edits) apply;
}

final viewRotationServerProvider = Provider<ViewRotationServer>(
  (ref) => ViewRotationServer(
    edits: (remoteId) => ref.read(driftProvider).remoteAssetRepository.getAssetEdits(remoteId),
    hasUnknownEdits: (remoteId) => ref.read(driftProvider).remoteAssetRepository.hasUnknownAssetEdits(remoteId),
    apply: (remoteId, edits) async => editReadyThumbhash(
      await applyAssetEdits(
        service: ref.read(assetServiceProvider),
        websocket: ref.read(websocketProvider.notifier),
        remoteId: remoteId,
        edits: edits,
      ),
    ),
  ),
);

/// A rotation on the server as the viewer sees it: [pending] quarter turns from the edits the session started from,
/// [shown] the turns the server's picture with each thumbhash carries, [saving] while a request runs
class RotationSession {
  const RotationSession({required this.pending, required this.shown, required this.saving});

  final int pending;
  final Map<String, int> shown;
  final bool saving;

  /// The quarter turns to draw on top of the server's picture whose thumbhash is [thumbhash]: what the user asked for
  /// beyond what that picture carries. 0 for a picture the session does not know (an edit made elsewhere, or one whose
  /// thumbhash the server did not send in time): the server's picture is shown as it is.
  int displayTurns(String? thumbhash) {
    final carried = shown[thumbhash ?? ''];
    return carried == null ? 0 : normalizeQuarterTurns(pending - carried);
  }
}

class _Session {
  _Session({
    required this.asset,
    required this.baseEdits,
    required this.deviceTurns,
    required String thumbhash,
    required this.mode,
  }) : pending = deviceTurns,
       shown = {thumbhash: 0};

  RemoteAsset asset;

  /// The edits on the server when the session started, as the database holds them; null when they could not be read
  final Future<List<AssetEdit>?> baseEdits;

  /// The turns kept on this device when the session started (made while the server took no edits): folded into the
  /// first request, and forgotten once the server holds them
  final int deviceTurns;

  /// Kept alive for the whole session, so that the mode is at hand when the debounce ends, the viewer gone or not
  final ProviderSubscription<RotationMode> mode;

  int pending;

  /// The turns the server holds now, from the base edits
  int serverTurns = 0;
  final Map<String, int> shown;
  Timer? debounce;
  Timer? expiry;
  bool saving = false;
  bool flushAgain = false;
  bool deviceTurnsCleared = false;

  bool get isIdle => debounce == null && !saving;

  RotationSession get view => RotationSession(pending: pending, shown: Map.unmodifiable(shown), saving: saving);
}

/// The rotations on the server, one session per asset, for the whole app: they outlive the viewer, so that a photo
/// turned and left at once is still saved.
///
/// A press turns the picture on screen at once and restarts a short wait ([debounce]); then the edits of the asset as
/// the session started, turned by all the presses so far (see [composeQuarterTurns]), replace those on the server, in
/// one request at a time, each carrying the whole list: the last one alone is right whatever happened before. Several
/// quick presses make one request, four make none. The mode is checked again before each request: an asset that became
/// 360° meanwhile sends nothing; one that carries edits the app does not know keeps its rotation on the device instead,
/// so that they are not lost.
///
/// The server answers with the thumbhash of its new picture, which the session maps to the turns it carries: the
/// viewer draws the turns asked for beyond those (see [RotationSession.displayTurns]), so that the regenerated picture
/// takes the place of the turned one in the same frame. A failed request drops the session: the server's picture comes
/// back, and a message says so.
class ViewRotationController extends Notifier<Map<String, RotationSession>> {
  /// How long the presses gather before a request
  static const debounce = Duration(milliseconds: 700);

  /// How long an idle session lasts after its last request
  static const lifetime = Duration(minutes: 2);

  final _sessions = <String, _Session>{};

  @override
  Map<String, RotationSession> build() {
    ref.onDispose(() {
      for (final session in _sessions.values) {
        _close(session);
      }
      _sessions.clear();
    });
    return const {};
  }

  /// Whether a request for [remoteId] runs now
  bool isSaving(String remoteId) => _sessions[remoteId]?.saving ?? false;

  /// Turns [asset] by [delta] quarter turns clockwise (negative: counter clockwise) on the server. Returns at once:
  /// the request follows the debounce.
  void rotate(RemoteAsset asset, int delta) {
    var session = _sessions[asset.id];
    if (session != null && session.isIdle && !session.shown.containsKey(asset.thumbHash ?? '')) {
      // The picture on screen is none the session made (edited elsewhere meanwhile): start again from its edits
      _end(session);
      session = null;
    }
    session ??= _start(asset);
    session
      ..asset = asset
      ..pending += delta;
    session.expiry?.cancel();
    session.expiry = null;
    session.debounce?.cancel();
    session.debounce = Timer(debounce, () {
      session!.debounce = null;
      unawaited(_flush(session));
    });
    _publish();
  }

  _Session _start(RemoteAsset asset) {
    final server = ref.read(viewRotationServerProvider);
    final baseEdits = server
        .edits(asset.id)
        .then<List<AssetEdit>?>(
          (edits) => edits,
          onError: (Object error, StackTrace stackTrace) {
            _log.warning('Could not read the edits of ${asset.id}', error, stackTrace);
            return null;
          },
        );
    final session = _Session(
      asset: asset,
      baseEdits: baseEdits,
      deviceTurns: ref.read(viewRotationsProvider.notifier).assetTurns(asset),
      thumbhash: asset.thumbHash ?? '',
      mode: ref.listen(rotationModeProvider(asset), (_, _) {}),
    );
    _sessions[asset.id] = session;
    return session;
  }

  Future<void> _flush(_Session session) async {
    if (!identical(_sessions[session.asset.id], session)) {
      return;
    }
    if (session.saving) {
      session.flushAgain = true;
      return;
    }
    session.expiry?.cancel();
    session.expiry = null;
    final asset = session.asset;
    final mode = session.mode.read();
    if (mode == RotationMode.none) {
      // Turned 360° (or found so) meanwhile: nothing is sent, nothing is kept
      _log.info('${asset.id} is no flat photo any more: its rotation is dropped');
      _end(session);
      return;
    }
    final server = ref.read(viewRotationServerProvider);
    final target = normalizeQuarterTurns(session.pending);
    session.saving = true;
    _publish();
    try {
      final hasUnknownEdits = await server.hasUnknownEdits(asset.id);
      final base = await session.baseEdits;
      if (!identical(_sessions[asset.id], session)) {
        return;
      }
      if (mode == RotationMode.device || hasUnknownEdits || base == null) {
        // Composing would drop edits the app does not know: the rotation stays on the device
        _keepOnDevice(session);
        return;
      }
      if (target != session.serverTurns) {
        final thumbhash = await server.apply(asset.id, composeQuarterTurns(base, target));
        session.serverTurns = target;
        if (thumbhash != null) {
          session.shown[thumbhash] = target;
        }
      }
      if (session.deviceTurns != 0 && !session.deviceTurnsCleared) {
        // The server holds them now
        session.deviceTurnsCleared = true;
        await ref.read(viewRotationsProvider.notifier).setAssetTurns(asset, 0);
      }
    } catch (error, stackTrace) {
      _log.warning('Could not save the rotation of ${asset.id}', error, stackTrace);
      if (identical(_sessions[asset.id], session)) {
        _end(session);
        unawaited(Future.sync(() => ref.read(toastServiceProvider).error(StaticTranslations.instance.rotate_failed)));
      }
      return;
    } finally {
      session.saving = false;
    }
    if (!identical(_sessions[asset.id], session)) {
      return;
    }
    final again = session.flushAgain;
    session.flushAgain = false;
    if (session.debounce != null) {
      // More presses: their own flush follows the debounce
    } else if (again) {
      unawaited(_flush(session));
    } else {
      session.expiry?.cancel();
      session.expiry = Timer(lifetime, () => _endIfIdle(session));
    }
    _publish();
  }

  void _keepOnDevice(_Session session) {
    final asset = session.asset;
    _end(session);
    // Beyond what the server already holds from this session
    unawaited(ref.read(viewRotationsProvider.notifier).setAssetTurns(asset, session.pending - session.serverTurns));
    showKeptOnDeviceOnce(ref.read(toastServiceProvider));
  }

  void _endIfIdle(_Session session) {
    if (identical(_sessions[session.asset.id], session) && session.isIdle) {
      _end(session);
    }
  }

  void _end(_Session session) {
    if (identical(_sessions[session.asset.id], session)) {
      _sessions.remove(session.asset.id);
    }
    _close(session);
    _publish();
  }

  void _close(_Session session) {
    session.debounce?.cancel();
    session.debounce = null;
    session.expiry?.cancel();
    session.expiry = null;
    session.mode.close();
  }

  void _publish() =>
      state = Map.unmodifiable({for (final MapEntry(:key, :value) in _sessions.entries) key: value.view});
}

final viewRotationControllerProvider = NotifierProvider<ViewRotationController, Map<String, RotationSession>>(
  ViewRotationController.new,
);

bool _keptOnDeviceShown = false;

@visibleForTesting
void resetKeptOnDeviceNotice() => _keptOnDeviceShown = false;

/// Says once per run that a rotation of an Immich photo stays on this device (an older server, a photo of someone
/// else, the read only mode): the user may expect it on the web
void showKeptOnDeviceOnce(ToastService toast) {
  if (_keptOnDeviceShown) {
    return;
  }
  _keptOnDeviceShown = true;
  unawaited(Future.sync(() => toast.info(StaticTranslations.instance.rotate_kept_on_device)));
}

/// The quarter turns clockwise the viewer draws [asset] with: none for a photo that does not turn (see
/// [rotationModeProvider]), whatever is kept for it; the turns of its session for one being turned on the server;
/// else the turns kept on this device, those of an Immich photo turned while its server took no edits included.
final displayQuarterTurnsProvider = Provider.autoDispose.family<int, BaseAsset>((ref, asset) {
  final mode = ref.watch(rotationModeProvider(asset));
  if (mode == RotationMode.none) {
    return 0;
  }
  if (mode == RotationMode.server && asset is RemoteAsset) {
    final session = ref.watch(viewRotationControllerProvider.select((sessions) => sessions[asset.id]));
    if (session != null) {
      return session.displayTurns(asset.thumbHash);
    }
  }
  return ref.watch(viewRotationsProvider.select((entries) => viewRotationTurnsOf(entries, asset)));
});

/// Whether a rotation of [remoteId] is being saved on the server, for the progress bar of the viewer
final rotationSavingProvider = Provider.autoDispose.family<bool, String>(
  (ref, remoteId) =>
      ref.watch(viewRotationControllerProvider.select((sessions) => sessions[remoteId]?.saving ?? false)),
);

/// Turns [asset] by [delta] quarter turns clockwise (negative: counter clockwise), as its mode says: on the server, or
/// on this device. False, and nothing done, for a photo that does not turn. Returns at once.
bool rotateAssetInViewer(Ref ref, BaseAsset asset, int delta) => _rotate(
  mode: ref.read(rotationModeProvider(asset)),
  controller: () => ref.read(viewRotationControllerProvider.notifier),
  rotations: () => ref.read(viewRotationsProvider.notifier),
  toast: () => ref.read(toastServiceProvider),
  asset: asset,
  delta: delta,
);

/// [rotateAssetInViewer] from a widget
bool rotateAssetFromWidget(WidgetRef ref, BaseAsset asset, int delta) => _rotate(
  mode: ref.read(rotationModeProvider(asset)),
  controller: () => ref.read(viewRotationControllerProvider.notifier),
  rotations: () => ref.read(viewRotationsProvider.notifier),
  toast: () => ref.read(toastServiceProvider),
  asset: asset,
  delta: delta,
);

bool _rotate({
  required RotationMode mode,
  required ViewRotationController Function() controller,
  required ViewRotations Function() rotations,
  required ToastService Function() toast,
  required BaseAsset asset,
  required int delta,
}) {
  switch (mode) {
    case RotationMode.none:
      return false;
    case RotationMode.server:
      controller().rotate(asset as RemoteAsset, delta);
      return true;
    case RotationMode.device:
      unawaited(rotations().rotateAsset(asset, delta));
      if (asset.hasRemote) {
        showKeptOnDeviceOnce(toast());
      }
      return true;
  }
}
