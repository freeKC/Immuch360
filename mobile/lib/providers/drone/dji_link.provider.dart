// The DJI link page: what the native side sees of a DJI remote controller plugged into this device as a USB accessory.
// The page asks for a snapshot when it opens and then follows the events; nothing here can send anything to an
// aircraft, and the only byte the native side ever writes is the liveness probe of the USB transport itself, which the
// page counts.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiLink');

/// The bridge to the native side. Tests replace it.
final djiLinkApiProvider = Provider<DjiLinkApi>((_) => DjiLinkApi());

/// The USB accessories the system lists right now, for the import page: strings only, no permission, nothing opened,
/// and the link page's owner is not made for it. An error (no bridge, as in a widget test) is an empty list.
final djiPluggedAccessoriesProvider = Provider<Future<List<DjiLinkPluggedAccessory>> Function()>(
  (ref) => () async {
    try {
      return await ref.read(djiLinkApiProvider).pluggedAccessories();
    } catch (error) {
      _log.fine('No accessory list: $error');
      return const [];
    }
  },
  dependencies: [djiLinkApiProvider],
);

/// Hands the events of the native side to a listener, null to stop. Tests replace it.
final djiLinkEventsSetUpProvider = Provider<void Function(DjiLinkEvents? events)>(
  (_) =>
      (events) => DjiLinkEvents.setUp(events),
);

/// Where the page stands
class DjiLinkPageState {
  const DjiLinkPageState({
    this.environment,
    this.snapshot,
    this.reading = false,
    this.listening = false,
    this.exporting = false,
    this.export,
    this.replay,
    this.error,
    this.profiles = const [],
    this.captures = const [],
    this.loadingCaptures = false,
    this.playError,
    this.bench = const DjiLinkBench(),
  });

  /// What this device can do about a USB accessory, read once when the page opens
  final DjiLinkEnvironment? environment;

  /// Everything about the link, as the native side last published it
  final DjiLinkSnapshot? snapshot;

  /// The environment is being read
  final bool reading;

  /// The native side is looking for an accessory and reading what arrives
  final bool listening;
  final bool exporting;

  /// Where the last export went, with its digest
  final DjiLinkExport? export;

  /// What a replayed capture file parsed to
  final DjiLinkReplayResult? replay;
  final String? error;

  /// The starting profiles the pilot can bind the accessory strings to ("Your hardware")
  final List<DjiLinkProfile> profiles;

  /// The captures this app can play, newest first
  final List<DjiLinkCaptureFile> captures;
  final bool loadingCaptures;

  /// Why the last capture did not play: busy, unreadable, empty, notPaired
  final String? playError;

  /// What the chips of the capture section say about the bench
  final DjiLinkBench bench;

  /// Whether this device can be the accessory end of the cable at all. False is an answer, not a failure.
  bool get transportPossible => environment?.transportPossible ?? false;

  /// Whether a remote holds the cable right now: a capture is not played while one does
  bool get linkOpen => switch (snapshot?.state) {
    DjiLinkState.accessoryOpen ||
    DjiLinkState.linkUsable ||
    DjiLinkState.controllerIdentified ||
    DjiLinkState.aircraftLinked ||
    DjiLinkState.videoReady ||
    DjiLinkState.telemetryReady => true,
    _ => false,
  };

  DjiLinkPageState copyWith({
    DjiLinkEnvironment? environment,
    DjiLinkSnapshot? snapshot,
    bool? reading,
    bool? listening,
    bool? exporting,
    DjiLinkExport? export,
    DjiLinkReplayResult? replay,
    String? error,
    List<DjiLinkProfile>? profiles,
    List<DjiLinkCaptureFile>? captures,
    bool? loadingCaptures,
    String? playError,
    DjiLinkBench? bench,
    bool clearError = false,
    bool clearExport = false,
    bool clearReplay = false,
    bool clearPlayError = false,
  }) => DjiLinkPageState(
    environment: environment ?? this.environment,
    snapshot: snapshot ?? this.snapshot,
    reading: reading ?? this.reading,
    listening: listening ?? this.listening,
    exporting: exporting ?? this.exporting,
    export: clearExport ? null : (export ?? this.export),
    replay: clearReplay ? null : (replay ?? this.replay),
    error: clearError ? null : (error ?? this.error),
    profiles: profiles ?? this.profiles,
    captures: captures ?? this.captures,
    loadingCaptures: loadingCaptures ?? this.loadingCaptures,
    playError: clearPlayError ? null : (playError ?? this.playError),
    bench: bench ?? this.bench,
  );
}

/// The bench as the chips of the capture section say it, kept in the header of an export as codes: cable original
/// or other; port top, bottom or phone; remote on; aircraft off, motorsOff, propellersOff or flying
class DjiLinkBench {
  const DjiLinkBench({this.cable, this.port, this.remote, this.aircraft});

  final String? cable;
  final String? port;
  final String? remote;
  final String? aircraft;

  static const cables = ['original', 'other'];
  static const ports = ['top', 'bottom', 'phone'];
  static const remotes = ['on'];
  static const aircraftStates = ['off', 'motorsOff', 'propellersOff', 'flying'];

  /// Tapping a chip that is on turns it off
  DjiLinkBench toggle(String field, String value) => DjiLinkBench(
    cable: field == 'cable' ? (cable == value ? null : value) : cable,
    port: field == 'port' ? (port == value ? null : value) : port,
    remote: field == 'remote' ? (remote == value ? null : value) : remote,
    aircraft: field == 'aircraft' ? (aircraft == value ? null : value) : aircraft,
  );

  DjiLinkExportNotes notes(String? note) =>
      DjiLinkExportNotes(cable: cable, port: port, remoteState: remote, aircraftState: aircraft, note: note);
}

class DjiLinkNotifier extends Notifier<DjiLinkPageState> implements DjiLinkEvents {
  DjiLinkApi get _api => ref.read(djiLinkApiProvider);

  bool _attached = false;

  @override
  DjiLinkPageState build() => const DjiLinkPageState();

  /// The page opened: read what this device can do, then start listening when it can do anything at all
  Future<void> pageShown() async {
    if (!_attached) {
      _attached = true;
      ref.read(djiLinkEventsSetUpProvider)(this);
    }
    state = state.copyWith(reading: true, clearError: true);
    try {
      final environment = await _api.readEnvironment();
      state = state.copyWith(environment: environment, reading: false);
      if (!environment.transportPossible) {
        _log.info('No USB accessory feature on this device: the DJI link page offers no start button');
        // A capture can still be played here, which measures this device's decoder with no remote at all
        await refresh();
        await listCaptures();
        return;
      }
      await start();
      await _loadProfiles();
      await listCaptures();
    } catch (error, stackTrace) {
      _log.warning('Could not read what this device can do about a USB accessory', error, stackTrace);
      state = state.copyWith(reading: false, error: error.toString());
    }
  }

  /// The page closed: the link stops with it, unless the relay still sends to a headset, which keeps it and keeps
  /// hearing the native side (the Stop of the notification). A relay still starting may have been started natively
  /// just before the page closed: the events stay attached for it too.
  Future<void> pageHidden() async {
    final relay = ref.read(djiRelayProvider);
    if (_attached && !relay.sending && !relay.starting) {
      _attached = false;
      ref.read(djiLinkEventsSetUpProvider)(null);
    }
    try {
      await _api.stop();
    } catch (error) {
      _log.fine('The link did not stop cleanly: $error');
    }
    state = state.copyWith(listening: false);
  }

  Future<void> start() async {
    try {
      await _api.start();
      state = state.copyWith(listening: true, clearError: true);
      await refresh();
    } catch (error, stackTrace) {
      _log.warning('Could not start looking for an accessory', error, stackTrace);
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> retry() async {
    try {
      await _api.retry();
    } catch (error) {
      _log.fine('The retry did not go through: $error');
    }
  }

  Future<void> refresh() async {
    try {
      state = state.copyWith(snapshot: await _api.snapshot());
    } catch (error) {
      _log.fine('No snapshot of the link: $error');
    }
  }

  Future<void> startCapture() async {
    await _api.startCapture();
    await refresh();
  }

  Future<void> stopCapture() async {
    await _api.stopCapture();
    await refresh();
  }

  Future<void> clearCapture() async {
    await _api.clearCapture();
    state = state.copyWith(clearExport: true);
    await refresh();
  }

  /// Writes the capture where the pilot can reach it, with what was typed about the bench in its header
  Future<void> exportCapture(DjiLinkExportNotes notes) async {
    state = state.copyWith(exporting: true, clearError: true, clearExport: true);
    try {
      final result = await _api.exportCapture(notes);
      state = state.copyWith(exporting: false, export: result);
      // The Logs page keeps a copy, so that a session that goes wrong still says where its evidence went
      if (result.ok && result.headerOnly) {
        _log.info('DJI link header exported with nothing captured: ${result.headerPath}');
      } else if (result.ok) {
        _log.info('DJI link capture exported: ${result.bytes} bytes, ${result.binPath}, sha256 ${result.sha256}');
      } else {
        _log.warning('DJI link capture not exported: ${result.error}');
      }
    } catch (error, stackTrace) {
      _log.warning('Could not export the DJI link capture', error, stackTrace);
      state = state.copyWith(exporting: false, error: error.toString());
    }
  }

  Future<void> _loadProfiles() async {
    try {
      state = state.copyWith(profiles: await _api.profiles());
    } catch (error) {
      _log.fine('No profiles: $error');
    }
  }

  /// Binds the accessory strings to a starting profile, null forgets; it names the hardware and nothing else
  Future<void> bindProfile(String? profileId) async {
    try {
      await _api.bindProfile(profileId);
      await refresh();
    } catch (error) {
      _log.fine('The binding did not go through: $error');
    }
  }

  Future<void> setDecoderChoice(DjiLinkDecoderChoice choice) async {
    try {
      await _api.setDecoderChoice(choice);
      await refresh();
    } catch (error) {
      _log.fine('The decoder choice did not go through: $error');
    }
  }

  void toggleBench(String field, String value) {
    state = state.copyWith(bench: state.bench.toggle(field, value));
  }

  Future<void> listCaptures() async {
    state = state.copyWith(loadingCaptures: true);
    try {
      state = state.copyWith(captures: await _api.listCaptures(), loadingCaptures: false);
    } catch (error) {
      _log.fine('No capture list: $error');
      state = state.copyWith(loadingCaptures: false);
    }
  }

  /// Plays a capture through the same pipeline as the cable, from [startAtMs], again from there at each end with [loop]
  Future<void> play(DjiLinkCaptureFile file, {int startAtMs = 0, bool loop = false}) async {
    state = state.copyWith(clearPlayError: true);
    try {
      final outcome = await _api.playCapture(file.binUri, file.indexUri, startAtMs, loop);
      if (outcome != null) {
        _log.info('The capture ${file.name} did not play: $outcome');
        state = state.copyWith(playError: outcome);
      } else {
        _log.info('Playing the capture ${file.name} from $startAtMs ms');
      }
      await refresh();
    } catch (error, stackTrace) {
      _log.warning('Could not play the capture', error, stackTrace);
      state = state.copyWith(playError: 'unreadable');
    }
  }

  /// The system picker for a .bin and its .idx.csv, then playing them
  Future<void> chooseAndPlay({int startAtMs = 0, bool loop = false}) async {
    state = state.copyWith(clearPlayError: true);
    try {
      final chosen = await _api.chooseCaptureFiles();
      if (chosen == null) {
        state = state.copyWith(playError: 'notPaired');
        return;
      }
      await play(chosen, startAtMs: startAtMs, loop: loop);
    } catch (error) {
      _log.fine('The picker did not answer: $error');
    }
  }

  Future<void> stopPlayback() async {
    try {
      await _api.stopPlayback();
      state = state.copyWith(clearPlayError: true);
      await refresh();
    } catch (error) {
      _log.fine('The playback did not stop cleanly: $error');
    }
  }

  /// A saved capture back through the same codecs, with no hardware. A seed given for either checksum replaces the
  /// one of the notes, typically the candidate the live page showed.
  Future<void> replay(String path, {int? headerCrcSeed, int? frameCrcSeed}) async {
    state = state.copyWith(clearReplay: true, clearError: true);
    try {
      final result = await _api.replayCapture(path, headerCrcSeed, frameCrcSeed);
      state = state.copyWith(replay: result);
      _log.info('DJI link capture replayed: ${result.bytesReplayed} bytes, ${result.readsReplayed} reads');
    } catch (error, stackTrace) {
      _log.warning('Could not replay the capture', error, stackTrace);
      state = state.copyWith(error: error.toString());
    }
  }

  @override
  void snapshotChanged(DjiLinkSnapshot snapshot) {
    state = state.copyWith(snapshot: snapshot);
    ref.read(djiRelayProvider.notifier).onSnapshot(snapshot);
  }

  /// Stop in the notification of "Send to a headset": the native relay stopped, the announcement stops here
  @override
  void relayStopRequested() {
    unawaited(ref.read(djiRelayProvider.notifier).onStopRequested());
  }
}

/// The dependencies are declared so that a scope which replaces the bridge (the tests, and the page of a later stage
/// that reads a capture file) is the one this notifier talks to
final djiLinkProvider = NotifierProvider<DjiLinkNotifier, DjiLinkPageState>(
  DjiLinkNotifier.new,
  dependencies: [djiLinkApiProvider, djiLinkEventsSetUpProvider, djiRelayProvider],
);
