// What the camera pages show of a Tapo camera: its recordings (the connection of its source, a TapoRecordings), its
// details and memory card, the days it recorded and the clips of a day, the size of what was fetched from it, and the
// live view API on Android. Each is a provider so that the tests of the pages give fakes instead.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('TapoCamera');

/// The time of [instant] where the camera stands: in its zone, else in the zone of this device. A DateTime marked UTC
/// whose fields are the local ones, for the formats of the pages.
DateTime cameraLocalTime(TapoCameraInfo? camera, DateTime instant) => TapoZone.of(camera?.zoneId).local(instant);

/// Whether the camera of a source id has the password of its TP-Link account: without it, the recordings are not read
/// and the connection is never opened
final tapoCameraHasCloudPasswordProvider = FutureProvider.autoDispose.family<bool, String>((ref, sourceId) async {
  ref.watch(networkSourceProvider(sourceId));
  return await ref.read(networkSourcesProvider.notifier).readPassword(sourceId) != null;
});

/// The password of the camera account of a source id (the live view), null when none was given
final tapoCameraAccountPasswordProvider = FutureProvider.autoDispose.family<String?, String>((ref, sourceId) async {
  ref.watch(networkSourceProvider(sourceId));
  return ref.read(networkSourcesProvider.notifier).readCameraPassword(sourceId);
});

/// The recordings of the camera of a source id, through its connection; null without a TP-Link password. Opened again
/// when the source changes (a new address, a new password, what a login learned).
final tapoRecordingsProvider = FutureProvider.autoDispose.family<TapoRecordings?, String>((ref, sourceId) async {
  final source = ref.watch(networkSourceProvider(sourceId));
  if (source == null || source.type != NetworkSourceType.tapo) {
    return null;
  }
  if (!await ref.watch(tapoCameraHasCloudPasswordProvider(sourceId).future)) {
    return null;
  }
  final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(sourceId);
  return fileSystem is TapoRecordings ? fileSystem as TapoRecordings : null;
});

/// Saves what the connection learned of the camera (its generation, the forms of its login, its model, its zone, the
/// certificate of a first login) when the source does not hold it yet. The write closes the connection; the login
/// stays in TapoSessionCache, so the next connection does not log in again.
Future<void> saveLearnedTapoInfo(Ref ref, String sourceId, TapoCameraInfo learned) async {
  final source = ref.read(networkSourceProvider(sourceId));
  if (source == null || source.camera == learned) {
    return;
  }
  final camera = (source.camera ?? const TapoCameraInfo()).copyWith(
    model: learned.model,
    firmware: learned.firmware,
    protocol: learned.protocol,
    passcode: learned.passcode,
    userName: learned.userName,
    zoneId: learned.zoneId,
    certificateSha256: learned.certificateSha256,
  );
  if (camera == source.camera) {
    return;
  }
  try {
    await ref.read(networkSourcesProvider.notifier).update(source.copyWith(camera: camera));
  } catch (error, stackTrace) {
    _log.warning('Could not keep what was learned about a camera', error, stackTrace);
  }
}

/// The details and the memory card of the camera of a source id
final tapoCameraStatusProvider = FutureProvider.autoDispose
    .family<({TapoCameraDetails details, TapoCardStatus card})?, String>((ref, sourceId) async {
      final recordings = await ref.watch(tapoRecordingsProvider(sourceId).future);
      if (recordings == null) {
        return null;
      }
      final details = await recordings.details();
      final card = await recordings.cardStatus();
      unawaited(saveLearnedTapoInfo(ref, sourceId, recordings.info));
      return (details: details, card: card);
    });

/// The days the camera of a source id recorded, newest first; refresh asks the camera again
class TapoCameraDaysNotifier extends AutoDisposeFamilyAsyncNotifier<List<String>, String> {
  @override
  Future<List<String>> build(String sourceId) async {
    final recordings = await ref.watch(tapoRecordingsProvider(sourceId).future);
    if (recordings == null) {
      return const [];
    }
    return recordings.days();
  }

  Future<void> refresh() async {
    final recordings = await ref.read(tapoRecordingsProvider(arg).future);
    if (recordings == null) {
      return;
    }
    state = const AsyncLoading<List<String>>().copyWithPrevious(state);
    state = await AsyncValue.guard(() => recordings.days(refresh: true));
  }
}

final tapoCameraDaysProvider = AsyncNotifierProvider.autoDispose.family<TapoCameraDaysNotifier, List<String>, String>(
  TapoCameraDaysNotifier.new,
);

/// The clips of a day ("yyyy-mm-dd" in the camera's zone) of the camera of a source id, oldest first
class TapoCameraClipsNotifier extends AutoDisposeFamilyAsyncNotifier<List<TapoClip>, (String, String)> {
  @override
  Future<List<TapoClip>> build((String, String) key) async {
    final recordings = await ref.watch(tapoRecordingsProvider(key.$1).future);
    if (recordings == null) {
      return const [];
    }
    return recordings.clips(key.$2);
  }

  Future<void> refresh() async {
    final recordings = await ref.read(tapoRecordingsProvider(arg.$1).future);
    if (recordings == null) {
      return;
    }
    state = const AsyncLoading<List<TapoClip>>().copyWithPrevious(state);
    state = await AsyncValue.guard(() => recordings.clips(arg.$2, refresh: true));
  }
}

final tapoCameraClipsProvider = AsyncNotifierProvider.autoDispose
    .family<TapoCameraClipsNotifier, List<TapoClip>, (String, String)>(TapoCameraClipsNotifier.new);

/// The bytes of the clips and pictures fetched from the camera of a source id
final tapoCameraCacheBytesProvider = FutureProvider.autoDispose.family<int, String>((ref, sourceId) async {
  final recordings = await ref.watch(tapoRecordingsProvider(sourceId).future);
  return recordings == null ? 0 : recordings.cacheBytes();
});

// The live view on Android (and on the Quest): the API that tells a platform view what to play, and the states the
// views report

/// One state of a live view
typedef CameraLiveEvent = ({CameraLiveState state, String? error, bool hasAudio});

final cameraLiveApiProvider = Provider<CameraLiveApi>((_) => CameraLiveApi());

/// Builds the platform view of a live view and calls back with its id once created; null for the real one of Android.
/// The tests give a stand in: a platform view needs the engine.
final cameraLivePlatformViewProvider = Provider<Widget Function(ValueChanged<int> onCreated)?>((_) => null);

/// The states of the live views, by view id; set up on first use, Android only
class CameraLiveEventsHub implements CameraLiveEvents {
  final Map<int, StreamController<CameraLiveEvent>> _views = {};
  bool _registered = false;

  /// The states of the view [viewId], until [release]
  Stream<CameraLiveEvent> of(int viewId) {
    if (!_registered && !kIsWeb && Platform.isAndroid) {
      _registered = true;
      CameraLiveEvents.setUp(this);
    }
    return _views.putIfAbsent(viewId, StreamController<CameraLiveEvent>.broadcast).stream;
  }

  void release(int viewId) => unawaited(_views.remove(viewId)?.close());

  @override
  void stateChanged(int viewId, CameraLiveState state, String? error, bool hasAudio) =>
      _views[viewId]?.add((state: state, error: error, hasAudio: hasAudio));
}

final cameraLiveEventsProvider = Provider<CameraLiveEventsHub>((_) => CameraLiveEventsHub());
