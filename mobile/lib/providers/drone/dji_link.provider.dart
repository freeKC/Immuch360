// The DJI live video and its Diagnostics: what the native side sees of a DJI remote controller plugged into this device
// as a USB accessory. The live screen (or the watch page of a headset) owns the session: it asks for a snapshot when it
// opens and then follows the events, and Diagnostics shows the same state. Nothing here can send anything to an
// aircraft, and the only byte the native side ever writes is the liveness probe of the USB transport itself, which
// Diagnostics counts.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
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

/// Tells the native side whether Settings, Advanced, "DJI live video (experimental)" is on: with it off, plugging the
/// remote never opens the app. An error (no bridge, as in a widget test) is only logged.
final djiLiveSettingSyncProvider = Provider<Future<void> Function(bool on)>(
  (ref) => (on) async {
    try {
      await ref.read(djiLinkApiProvider).setLiveSettingOn(on);
    } catch (error) {
      _log.fine('The setting did not reach the native side: $error');
    }
  },
  dependencies: [djiLinkApiProvider],
);

/// What the live screen keeps on this install, in the app's store: a live picture was seen once, and the offer to open
/// the screen on the plug of the remote was answered. Tests replace it.
class DjiLiveMemory {
  const DjiLiveMemory({
    required this.read,
    required this.write,
    this.readInt = _noNumber,
    this.writeInt = _dropNumber,
  });

  final bool Function(StoreKey<bool> key) read;
  final Future<void> Function(StoreKey<bool> key, bool value) write;

  /// A number kept, null when never set (the distances of the obstacle ring, in centimetres)
  final int? Function(StoreKey<int> key) readInt;
  final Future<void> Function(StoreKey<int> key, int value) writeInt;
}

int? _noNumber(StoreKey<int> key) => null;

Future<void> _dropNumber(StoreKey<int> key, int value) async {}

/// The DJI settings no longer read since the build of 25 October, when every switch became on by default and kept as
/// "turned off" under a key of its own: their numbers stay taken in [StoreKey], so that they are never given again,
/// and what an earlier build stored under them is removed ([djiForgetRetiredSettings])
const djiRetiredSettings = <StoreKey<bool>>[
  StoreKey.djiObstacleAlertOn,
  StoreKey.djiHeadsetLowestDelay,
  StoreKey.djiObstacleHapticOn,
  StoreKey.djiObstacleNumbersOn,
  StoreKey.djiObstacleTvSoundOn,
];

/// Removes the values of [djiRetiredSettings] an earlier build left in [store], at the app's start; writes nothing when
/// none is there. A failure is only logged: the values are not read anyway.
Future<void> djiForgetRetiredSettings(StoreService store) async {
  try {
    for (final key in djiRetiredSettings) {
      if (store.tryGet(key) != null) {
        await store.delete(key);
      }
    }
  } catch (error) {
    _log.fine('The retired DJI settings stay for now: $error');
  }
}

final djiLiveMemoryProvider = Provider<DjiLiveMemory>((ref) {
  final store = ref.watch(storeServiceProvider);
  return DjiLiveMemory(
    read: (key) => store.tryGet(key) ?? false,
    write: (key, value) => store.put(key, value),
    readInt: (key) => store.tryGet(key),
    writeInt: (key, value) => store.put(key, value),
  );
});

/// Hands the events of the native side to a listener, null to stop. Tests replace it.
final djiLinkEventsSetUpProvider = Provider<void Function(DjiLinkEvents? events)>(
  (_) =>
      (events) => DjiLinkEvents.setUp(events),
);

/// What a tap on "Save a capture" or "Save a reception record" gave, for its toast (p2/design-final-2026-10-24.md, 6)
enum DjiLinkExportOutcome {
  /// The files were written: the toast names them
  saved,

  /// Nothing new since the last export: no file was written, the toast names the last one
  repeated,

  /// Nothing to save yet: no remote opened in this session (the live screen), nothing received (a headset)
  nothing,

  /// The files could not be written: Diagnostics says why
  failed,

  /// An export was already under way: this tap did nothing
  busy,
}

/// The folder and the name without its extensions of an exported file, for the toast: Download/Immuch360/dji-link and
/// dji-link-20261024-121915
(String folder, String name) djiExportName(String path) {
  final slash = path.lastIndexOf('/');
  final folder = slash < 0 ? '' : path.substring(0, slash);
  var name = slash < 0 ? path : path.substring(slash + 1);
  for (final extension in const ['.idx.csv', '.bin', '.json']) {
    if (name.endsWith(extension)) {
      name = name.substring(0, name.length - extension.length);
      break;
    }
  }
  return (folder, name);
}

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
    this.openOnPlug = false,
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

  /// "Open this screen when the remote is plugged in", as the native side keeps it
  final bool openOnPlug;

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
    bool? openOnPlug,
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
    openOnPlug: openOnPlug ?? this.openOnPlug,
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

  /// The live screen or the watch page opened: read what this device can do, then start listening when it can do
  /// anything at all. With [capture], the capture starts with the link, so that a bug report always holds the head of
  /// the session. The capture of the last session is kept until a remote opens (the native side forgets it at that
  /// open), so that a pilot who comes back to save it after a problem still finds it; with a remote open already, the
  /// new session is under way and its capture starts fresh at once.
  Future<void> pageShown({bool capture = false}) async {
    if (!_attached) {
      _attached = true;
      ref.read(djiLinkEventsSetUpProvider)(this);
    }
    // A new session: no value of the last one is drawn before its first frame
    ref.read(djiLiveFrameProvider.notifier).clear();
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
      // A new capture for a new session; a link the relay kept running keeps the capture it has
      if (capture && state.snapshot?.capture.recording != true) {
        if (state.linkOpen) {
          await _api.clearCapture();
        }
        await startCapture();
      }
      await _loadOpenOnPlug();
      await _loadProfiles();
      await listCaptures();
    } catch (error, stackTrace) {
      _log.warning('Could not read what this device can do about a USB accessory', error, stackTrace);
      state = state.copyWith(reading: false, error: error.toString());
    }
  }

  /// The live screen or the watch page closed: the link stops with it, unless the relay still sends to a headset, which
  /// keeps it and keeps hearing the native side (the Stop of the notification). A relay still starting may have been
  /// started natively just before the page closed: the events stay attached for it too.
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
      final snapshot = await _api.snapshot();
      state = state.copyWith(snapshot: snapshot);
      ref.read(djiLiveFrameProvider.notifier).offer(snapshot.liveFrame);
    } catch (error) {
      _log.fine('No snapshot of the link: $error');
    }
  }

  /// A screen with the picture is in front or not: the values come ten times a second while it is, and the obstacle
  /// sound may play. An error (no bridge, as in a widget test) is only logged.
  Future<void> setFrameStream(bool on) async {
    try {
      await _api.setFrameStream(on);
    } catch (error) {
      _log.fine('The frame stream did not change: $error');
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

  /// Writes the capture where the pilot can reach it, with what was typed about the bench in its header. One export at
  /// a time: a tap while one runs does nothing, and the native side answers a tap with nothing new as repeated.
  Future<DjiLinkExportOutcome> exportCapture(DjiLinkExportNotes notes) async {
    if (state.exporting) {
      _log.info('DJI link export asked again while one runs: nothing more done');
      return DjiLinkExportOutcome.busy;
    }
    state = state.copyWith(exporting: true, clearError: true, clearExport: true);
    try {
      final result = await _api.exportCapture(notes);
      state = state.copyWith(exporting: false, export: result);
      // The Logs page keeps a copy, so that a session that goes wrong still says where its evidence went
      if (result.ok && result.repeated) {
        _log.info('DJI link capture not written again, nothing new since ${result.binPath ?? result.headerPath}');
        return DjiLinkExportOutcome.repeated;
      } else if (result.ok && result.headerOnly) {
        _log.info('DJI link header exported with nothing captured: ${result.headerPath}');
      } else if (result.ok) {
        _log.info(
          'DJI link capture exported: ${result.bytes} bytes, ${result.binPath}, sha256 ${result.sha256}, '
          'control frames ${result.controlBinPath}',
        );
      } else {
        _log.warning('DJI link capture not exported: ${result.error}');
        return DjiLinkExportOutcome.failed;
      }
      return DjiLinkExportOutcome.saved;
    } catch (error, stackTrace) {
      _log.warning('Could not export the DJI link capture', error, stackTrace);
      state = state.copyWith(exporting: false, error: error.toString());
      return DjiLinkExportOutcome.failed;
    }
  }

  /// A headset's reception record: what it received from the phone and how it decoded it. One at a time, nothing
  /// written when nothing was received or nothing new came since the last one.
  Future<DjiLinkExportOutcome> exportReception() async {
    if (state.exporting) {
      return DjiLinkExportOutcome.busy;
    }
    state = state.copyWith(exporting: true, clearError: true, clearExport: true);
    try {
      final result = await _api.exportReception();
      state = state.copyWith(exporting: false, export: result);
      if (result.ok && result.nothing) {
        _log.info('DJI reception record: nothing received, nothing written');
        return DjiLinkExportOutcome.nothing;
      } else if (result.ok && result.repeated) {
        _log.info('DJI reception record not written again, nothing new since ${result.binPath}');
        return DjiLinkExportOutcome.repeated;
      } else if (result.ok) {
        _log.info('DJI reception record exported: ${result.bytes} bytes, ${result.binPath}, sha256 ${result.sha256}');
        return DjiLinkExportOutcome.saved;
      }
      _log.warning('DJI reception record not exported: ${result.error}');
      return DjiLinkExportOutcome.failed;
    } catch (error, stackTrace) {
      _log.warning('Could not export the DJI reception record', error, stackTrace);
      state = state.copyWith(exporting: false, error: error.toString());
      return DjiLinkExportOutcome.failed;
    }
  }

  /// Diagnostics opened over the live screen: the latest snapshot and lists, without starting or stopping anything
  Future<void> diagnosticsShown() async {
    await refresh();
    await _loadProfiles();
    await listCaptures();
  }

  Future<void> _loadOpenOnPlug() async {
    try {
      state = state.copyWith(openOnPlug: await _api.openOnPlug());
    } catch (error) {
      _log.fine('No answer for opening on the plug: $error');
    }
  }

  /// "Open this screen when the remote is plugged in"
  Future<void> setOpenOnPlug(bool on) async {
    try {
      await _api.setOpenOnPlug(on);
      state = state.copyWith(openOnPlug: on);
    } catch (error) {
      _log.fine('Opening on the plug did not change: $error');
    }
  }

  /// "Save a capture for a bug report" on the live screen: the capture as it is, with no bench notes (they stay in
  /// Diagnostics). With no remote opened in this session and no session kept, nothing is written: the header alone
  /// would say nothing the pilot can use, and three taps once made three of them.
  Future<DjiLinkExportOutcome> exportForBugReport() async {
    if (state.exporting) {
      return DjiLinkExportOutcome.busy;
    }
    final capture = state.snapshot?.capture;
    if (capture == null || (capture.totalBytes == 0 && capture.records == 0)) {
      _log.info('DJI link capture: nothing to save yet, no remote opened in this session');
      return DjiLinkExportOutcome.nothing;
    }
    return exportCapture(DjiLinkExportNotes());
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
    ref.read(djiLiveFrameProvider.notifier).offer(snapshot.liveFrame);
    ref.read(djiRelayProvider.notifier).onSnapshot(snapshot);
  }

  /// The values a pilot reads, ten times a second: their own provider, so that the page is not rebuilt for them
  @override
  void flightChanged(DjiLiveFrame frame) {
    ref.read(djiLiveFrameProvider.notifier).offer(frame);
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
  dependencies: [djiLinkApiProvider, djiLinkEventsSetUpProvider, djiRelayProvider, djiLiveFrameProvider],
);
