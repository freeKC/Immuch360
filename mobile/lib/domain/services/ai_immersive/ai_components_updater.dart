// The update of the installed AI components (issue 21, store/m2/release-52/ai-components-update-2026-11-24.md): the
// components a new version of the app carries in a newer version than the one on the disk, found by the service from
// the catalogue built into the app (no other address is asked), and brought up to date one after the other through
// the downloads the service already makes: their progress, the .part kept by a pause and resumed by Range, the sum of
// each file checked, the free space of the drive read before the first byte, and the older version kept until the
// new one is checked. Only the components the user installed are updated; nothing new is downloaded.
//
// Above [aiUpdateConfirmBytes] to download, or on a metered connection, the user is asked first. The automatic update
// (a setting of the computers, on by default as every feature of this lab) starts by itself only on a connection that
// is not metered and below that size; otherwise the notice of the updates stays for the user. A failed update leaves
// its older version in place (offline, a file that is not the one of the catalogue, a full drive), and the others go
// on but after a cut connection or a full drive, which would fail them too.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:logging/logging.dart';

final _log = Logger('AiComponentsUpdater');

/// Above this many bytes to download, an update asks first and the automatic update does not start by itself
const aiUpdateConfirmBytes = 1024 * 1024 * 1024;

/// Where the update is
enum AiUpdatePhase { idle, running, paused, done, failed }

/// What an update did
enum AiUpdateOutcome {
  /// Every update asked is installed
  updated,

  /// No component installed has a newer version
  nothing,

  /// Above the size limit or on a metered connection: asked first, then called again with confirmed
  needsConfirmation,

  /// Paused: the bytes received stay for Resume
  paused,

  /// No connection: the installed versions stay, tried again later
  offline,

  /// The drive of the components lacks the space: nothing downloaded
  notEnoughSpace,

  /// A conversion runs, or the components are being moved: nothing downloaded
  busy,

  /// One update at least did not install; its older version stays
  failed,

  /// The automatic update did not start: off, a metered connection, or too large
  notStarted,
}

/// What the user is asked before an update: the bytes to download, and whether the connection is metered
class AiUpdateAsk {
  const AiUpdateAsk({required this.bytes, required this.metered});

  final int bytes;
  final bool metered;
}

/// See the top of this file
class AiComponentsUpdater extends ChangeNotifier {
  AiComponentsUpdater({
    required this.service,
    this.platform,
    Future<bool?> Function()? metered,
    Future<void> Function()? beforeUpdate,
    this.confirmAbove = aiUpdateConfirmBytes,
  }) : _metered = metered ?? _notMetered,
       _beforeUpdate = beforeUpdate ?? _nothing {
    service.addListener(_onService);
  }

  final AiComponentsService service;

  /// The system whose components are updated, all of the catalogue when null
  final AiPlatform? platform;

  /// Whether the connection is metered now; null when the system does not tell, taken as not metered
  final Future<bool?> Function() _metered;

  /// Lets go of what holds the components (the engines kept between two conversions) before the first download
  final Future<void> Function() _beforeUpdate;
  final int confirmAbove;

  static Future<bool?> _notMetered() async => false;
  static Future<void> _nothing() async {}

  List<AiComponentUpdate> _updates = const [];
  AiUnusedFiles _unused = const AiUnusedFiles();
  AiUpdatePhase _phase = AiUpdatePhase.idle;
  AiComponent? _current;
  int _doneBytes = 0;
  int _totalBytes = 0;
  List<AiComponent> _failed = const [];
  AiDownloadException? _failure;
  AiUpdateOutcome? _outcome;
  Future<AiUpdateOutcome>? _running;
  bool _pausing = false;

  /// The components the paused run had still to update, null for all of them
  List<String>? _pausedOnly;
  bool _disposed = false;

  /// The updates found by the last refresh
  List<AiComponentUpdate> get updates => _updates;

  /// What the update of all of them downloads
  int get updateBytes => _updates.fold(0, (sum, update) => sum + update.downloadBytes);

  /// What no component needs any more, found by the last refresh
  AiUnusedFiles get unused => _unused;
  AiUpdatePhase get phase => _phase;

  /// The component being downloaded
  AiComponent? get current => _current;

  /// The bytes of this run: received so far, and to download in all
  int get receivedBytes {
    final current = _current;
    if (current == null) {
      return _doneBytes;
    }
    final status = service.statusOf(current);
    return _doneBytes + (status.state == AiComponentState.downloading ? status.received : 0);
  }

  int get totalBytes => _totalBytes;

  /// The components of the last run that did not update, with the last failure
  List<AiComponent> get failed => _failed;
  AiDownloadException? get failure => _failure;

  /// What the last run did, null before any
  AiUpdateOutcome? get outcome => _outcome;

  bool get isRunning => _phase == AiUpdatePhase.running;

  void _onService() {
    if (isRunning) {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    service.removeListener(_onService);
    super.dispose();
  }

  /// Reads again the updates and what is unused
  Future<void> refresh() async {
    try {
      await service.load();
      _updates = service.updates(platform: platform);
      _unused = await service.unusedFiles();
    } catch (error, stack) {
      _log.warning('the AI components could not be read', error, stack);
    }
    _notify();
  }

  /// What the user is asked before [bytes] are downloaded, null when nothing is: below the limit on a connection that
  /// is not metered
  Future<AiUpdateAsk?> askFor(int bytes) async {
    final metered = await _isMetered();
    return bytes > confirmAbove || metered ? AiUpdateAsk(bytes: bytes, metered: metered) : null;
  }

  Future<bool> _isMetered() async {
    try {
      return await _metered() ?? false;
    } catch (error) {
      _log.info('whether the connection is metered is not known: $error');
      return false;
    }
  }

  /// Updates every installed component that has a newer version
  Future<AiUpdateOutcome> updateAll({bool confirmed = false}) => _start(null, confirmed: confirmed);

  /// Updates [component] alone
  Future<AiUpdateOutcome> update(AiComponent component, {bool confirmed = false}) =>
      _start([component.id], confirmed: confirmed);

  /// Stops the download under way; its bytes stay for [resume]
  void pause() {
    if (!isRunning) {
      return;
    }
    _pausing = true;
    final current = _current;
    if (current != null) {
      service.cancel(current);
    }
  }

  /// Goes on with what the pause left, from the bytes received
  Future<AiUpdateOutcome> resume() => _start(_pausedOnly, confirmed: true);

  /// The automatic update at the start of the app: when [enabled], on a connection that is not metered, and for at
  /// most [confirmAbove] bytes; otherwise the notice stays for the user
  Future<AiUpdateOutcome> automatic({required bool enabled}) async {
    if (_running != null || _phase == AiUpdatePhase.paused) {
      return AiUpdateOutcome.notStarted;
    }
    await refresh();
    if (_updates.isEmpty) {
      return AiUpdateOutcome.nothing;
    }
    if (!enabled || updateBytes > confirmAbove || await _isMetered()) {
      _log.info(
        '${_updates.length} AI components can be updated, ${updateBytes ~/ (1024 * 1024)} MiB: left to the user',
      );
      return AiUpdateOutcome.notStarted;
    }
    return updateAll(confirmed: true);
  }

  /// Deletes what no component needs any more
  Future<AiRemoveOutcome> removeUnused() async {
    final outcome = await service.removeUnused();
    await refresh();
    return outcome;
  }

  Future<AiUpdateOutcome> _start(List<String>? only, {required bool confirmed}) {
    final running = _running;
    if (running != null) {
      return running;
    }
    final run = _running = _run(only, confirmed: confirmed);
    return run.whenComplete(() => _running = null);
  }

  Future<AiUpdateOutcome> _run(List<String>? only, {required bool confirmed}) async {
    await refresh();
    final queue = [
      for (final update in _updates)
        if (only == null || only.contains(update.component.id)) update.component,
    ];
    if (queue.isEmpty) {
      return _end(AiUpdateOutcome.nothing, AiUpdatePhase.idle);
    }
    if (service.inUse() || service.isMoving) {
      return _end(AiUpdateOutcome.busy, _phase == AiUpdatePhase.paused ? AiUpdatePhase.paused : AiUpdatePhase.idle);
    }
    final bytes = AiComponentsService.downloadBytesOf(queue);
    if (!confirmed && await askFor(bytes) != null) {
      return AiUpdateOutcome.needsConfirmation;
    }
    final shortage = await service.spaceShortage(queue);
    if (shortage != null) {
      _failure = AiDownloadException(AiDownloadFailure.notEnoughSpace, '$shortage', shortage);
      return _end(AiUpdateOutcome.notEnoughSpace, AiUpdatePhase.failed);
    }
    try {
      await _beforeUpdate();
    } catch (error, stack) {
      _log.warning('what holds the AI components could not be let go', error, stack);
    }
    _phase = AiUpdatePhase.running;
    _pausing = false;
    _pausedOnly = null;
    _totalBytes = bytes;
    _doneBytes = 0;
    _failed = const [];
    _failure = null;
    _notify();
    final failed = <AiComponent>[];
    AiUpdateOutcome? stop;
    for (final (index, component) in queue.indexed) {
      if (_pausing) {
        stop = AiUpdateOutcome.paused;
        _pausedOnly = [for (final left in queue.skip(index)) left.id];
        break;
      }
      _current = component;
      _notify();
      try {
        await service.install(component);
        _log.info('${component.id} updated to ${component.version}');
      } on AiDownloadException catch (error) {
        _log.warning('${component.id} was not updated: $error');
        if (error.failure == AiDownloadFailure.cancelled) {
          stop = AiUpdateOutcome.paused;
          _pausedOnly = [for (final left in queue.skip(index)) left.id];
          break;
        }
        _failure = error;
        failed.add(component);
        // What would fail every other one too stops the run
        if (error.failure == AiDownloadFailure.network) {
          stop = AiUpdateOutcome.offline;
          break;
        }
        if (error.failure == AiDownloadFailure.diskFull || error.failure == AiDownloadFailure.notEnoughSpace) {
          stop = AiUpdateOutcome.notEnoughSpace;
          break;
        }
      }
      _doneBytes += AiComponentsService.downloadBytesOf([component]);
    }
    _current = null;
    _failed = failed;
    await refresh();
    return switch (stop) {
      AiUpdateOutcome.paused => _end(AiUpdateOutcome.paused, AiUpdatePhase.paused),
      final AiUpdateOutcome outcome => _end(outcome, AiUpdatePhase.failed),
      null when failed.isNotEmpty => _end(AiUpdateOutcome.failed, AiUpdatePhase.failed),
      null => _end(AiUpdateOutcome.updated, AiUpdatePhase.done),
    };
  }

  AiUpdateOutcome _end(AiUpdateOutcome outcome, AiUpdatePhase phase) {
    _outcome = outcome;
    _phase = phase;
    _notify();
    return outcome;
  }
}
