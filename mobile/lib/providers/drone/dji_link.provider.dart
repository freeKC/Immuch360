// The DJI link page: what the native side sees of a DJI remote controller plugged into this device as a USB accessory.
// The page asks for a snapshot when it opens and then follows the events; nothing here can send anything to an
// aircraft, and the only byte the native side ever writes is the liveness probe of the USB transport itself, which the
// page counts.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('DjiLink');

/// The bridge to the native side. Tests replace it.
final djiLinkApiProvider = Provider<DjiLinkApi>((_) => DjiLinkApi());

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

  /// Whether this device can be the accessory end of the cable at all. False is an answer, not a failure.
  bool get transportPossible => environment?.transportPossible ?? false;

  DjiLinkPageState copyWith({
    DjiLinkEnvironment? environment,
    DjiLinkSnapshot? snapshot,
    bool? reading,
    bool? listening,
    bool? exporting,
    DjiLinkExport? export,
    DjiLinkReplayResult? replay,
    String? error,
    bool clearError = false,
    bool clearExport = false,
    bool clearReplay = false,
  }) => DjiLinkPageState(
    environment: environment ?? this.environment,
    snapshot: snapshot ?? this.snapshot,
    reading: reading ?? this.reading,
    listening: listening ?? this.listening,
    exporting: exporting ?? this.exporting,
    export: clearExport ? null : (export ?? this.export),
    replay: clearReplay ? null : (replay ?? this.replay),
    error: clearError ? null : (error ?? this.error),
  );
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
        return;
      }
      await start();
    } catch (error, stackTrace) {
      _log.warning('Could not read what this device can do about a USB accessory', error, stackTrace);
      state = state.copyWith(reading: false, error: error.toString());
    }
  }

  /// The page closed: the link belongs to the page, so it stops with it
  Future<void> pageHidden() async {
    if (_attached) {
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
      if (result.ok) {
        _log.info('DJI link capture exported: ${result.bytes} bytes, ${result.binPath}, sha256 ${result.sha256}');
      } else {
        _log.warning('DJI link capture not exported: ${result.error}');
      }
    } catch (error, stackTrace) {
      _log.warning('Could not export the DJI link capture', error, stackTrace);
      state = state.copyWith(exporting: false, error: error.toString());
    }
  }

  /// A saved capture back through the same codecs, with no hardware
  Future<void> replay(String path) async {
    state = state.copyWith(clearReplay: true, clearError: true);
    try {
      final result = await _api.replayCapture(path);
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
  }
}

/// The dependencies are declared so that a scope which replaces the bridge (the tests, and the page of a later stage
/// that reads a capture file) is the one this notifier talks to
final djiLinkProvider = NotifierProvider<DjiLinkNotifier, DjiLinkPageState>(
  DjiLinkNotifier.new,
  dependencies: [djiLinkApiProvider, djiLinkEventsSetUpProvider],
);
