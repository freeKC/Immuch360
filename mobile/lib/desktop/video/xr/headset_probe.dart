// The headset probe of Immuch360 Desktop (store/m2/release-48/xr-probe.md, phase 0 of the PC VR study of
// 11 November 2026): "View in headset (probe)" in the 360° player and the flat player, behind the switch "Headset view
// (probe, experimental)" of the video settings, Windows only, in a build whose media_kit_360 has the headset probe
// (MEDIA_KIT_360_XR, package:media_kit_video/xr.dart). It shows the player's frame in a PC VR headset through whatever
// OpenXR runtime is active (SteamVR, Meta Horizon Link, Virtual Desktop, Pico Connect): around the head for a 360° or
// 180° video, on a flat screen for a film, or a test pattern with no video at all. The window keeps every control;
// the headset has none yet. Each start writes a log file in the support folder (xr-probe/), which the owner sends back
// after a session with his headset.
//
// The switch is off by default, unlike the lab's experimental features: this is a probe for a test session, and its
// button would only show "no OpenXR runtime" to anyone without a PC VR headset. Kept in desktop_xr.json of the support
// folder, written as the other desktop settings files are (a whole new file renamed over the old one).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/xr.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('HeadsetProbe');

/// The switch of the probe, in desktop_xr.json
class HeadsetProbeSettings {
  HeadsetProbeSettings({Future<Directory> Function()? folder}) : _folder = folder ?? getApplicationSupportDirectory;

  /// The app's settings, loaded at the first use
  static final shared = HeadsetProbeSettings();

  final Future<Directory> Function() _folder;
  final enabled = ValueNotifier<bool>(false);
  Future<void>? _loaded;

  static const fileName = 'desktop_xr.json';

  Future<void> load() => _loaded ??= _read();

  Future<void> _read() async {
    try {
      final file = File(p.join((await _folder()).path, fileName));
      if (file.existsSync()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['probe'] is bool) {
          enabled.value = decoded['probe'] as bool;
        }
      }
    } catch (error) {
      _log.warning('$fileName could not be read: $error');
    }
  }

  Future<void> setEnabled(bool value) async {
    await load();
    enabled.value = value;
    try {
      final folder = await _folder();
      await folder.create(recursive: true);
      final file = File(p.join(folder.path, fileName));
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode({'probe': value}), flush: true);
      await temporary.rename(file.path);
    } catch (error) {
      _log.warning('$fileName could not be written: $error');
    }
  }

  /// The log file of a new start: `xr-probe/xr-probe-DATE-TIME.log` of the support folder
  Future<String> newLogPath({DateTime? now}) async {
    final at = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${at.year}${two(at.month)}${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}';
    final folder = Directory(p.join((await _folder()).path, 'xr-probe'));
    await folder.create(recursive: true);
    return p.join(folder.path, 'xr-probe-$stamp.log');
  }
}

/// The calls of the probe, replaced by the tests
abstract interface class HeadsetProbeApi {
  Future<XrProbeResult> start({
    int? handle,
    required XrProbeMode mode,
    XrProbeStereo stereo,
    double fps,
    double yaw,
    required String logPath,
    String label,
  });
  Future<bool> stop();
  Future<void> recenter();
  Future<XrProbeState> state();
}

class PluginHeadsetProbeApi implements HeadsetProbeApi {
  const PluginHeadsetProbeApi();

  @override
  Future<XrProbeResult> start({
    int? handle,
    required XrProbeMode mode,
    XrProbeStereo stereo = XrProbeStereo.mono,
    double fps = 0,
    double yaw = 0,
    required String logPath,
    String label = '',
  }) => XrProbe.start(handle: handle, mode: mode, stereo: stereo, fps: fps, yaw: yaw, logPath: logPath, label: label);

  @override
  Future<bool> stop() => XrProbe.stop();

  @override
  Future<void> recenter() => XrProbe.recenter();

  @override
  Future<XrProbeState> state() => XrProbe.state();
}

/// What a player gives the probe when it starts: its handle (renderer C on for it, [prepare] turns it on when the
/// player does not draw through it), the stereo layout of its frame, its frame rate, the window's yaw and a label for
/// the log (what kind of video, never a URL or a token)
@immutable
class HeadsetProbeTarget {
  const HeadsetProbeTarget({
    required this.handle,
    required this.modes,
    this.stereo = XrProbeStereo.mono,
    this.fps = 0,
    this.yaw = 0,
    this.label = '',
    this.prepare,
    this.release,
  });

  final Future<int?> Function() handle;

  /// The modes the player offers, the first one being its own
  final List<XrProbeMode> modes;
  final XrProbeStereo stereo;
  final double fps;
  final double yaw;
  final String label;

  /// Before the start (renderer C on for a flat player), and after the stop
  final Future<bool> Function()? prepare;
  final Future<void> Function()? release;
}

/// Whether the probe's entries show: the switch on, Windows, and a build that has the probe
class HeadsetProbeAvailability {
  HeadsetProbeAvailability({HeadsetProbeSettings? settings, HeadsetProbeApi? api, bool? windows})
    : settings = settings ?? HeadsetProbeSettings.shared,
      api = api ?? const PluginHeadsetProbeApi(),
      windows = windows ?? Platform.isWindows;

  static HeadsetProbeAvailability? _shared;
  static HeadsetProbeAvailability get shared => _shared ??= HeadsetProbeAvailability();
  @visibleForTesting
  static set shared(HeadsetProbeAvailability value) => _shared = value;

  final HeadsetProbeSettings settings;
  final HeadsetProbeApi api;
  final bool windows;
  Future<bool>? _compiled;

  /// Whether this build's plugin has the probe, asked once
  Future<bool> compiled() => _compiled ??= windows ? api.state().then((state) => state.compiled) : Future.value(false);
}

/// "View in headset (probe)": a button with the probe's menu, shown only while [HeadsetProbeAvailability] says so
class HeadsetProbeButton extends StatefulWidget {
  const HeadsetProbeButton({super.key, required this.target, this.availability, this.color = Colors.white});

  /// What to show, read at each start (the view and the layout change while the page is open)
  final HeadsetProbeTarget Function() target;
  final HeadsetProbeAvailability? availability;

  /// The icon's colour: white over a video
  final Color color;

  @override
  State<HeadsetProbeButton> createState() => _HeadsetProbeButtonState();
}

enum _Action { sphere, screen, pattern24, pattern30, recenter, stop }

class _HeadsetProbeButtonState extends State<HeadsetProbeButton> {
  late final HeadsetProbeAvailability _availability = widget.availability ?? HeadsetProbeAvailability.shared;
  bool _compiled = false;
  bool _active = false;
  String? _status;
  Timer? _poll;
  HeadsetProbeTarget? _started;

  @override
  void initState() {
    super.initState();
    unawaited(_availability.settings.load());
    unawaited(
      _availability.compiled().then((compiled) {
        if (mounted) {
          setState(() => _compiled = compiled);
        }
      }),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (_active) {
      // The page goes: so does its headset view, and renderer C of a flat player
      final started = _started;
      unawaited(_availability.api.stop().then((_) => started?.release?.call()));
    }
    super.dispose();
  }

  Future<void> _start(XrProbeMode mode, {double? fps}) async {
    final target = widget.target();
    if (_active) {
      await _stop();
    }
    if (mode != XrProbeMode.pattern && target.prepare != null && !await target.prepare!()) {
      _show('the player cannot draw for the headset');
      return;
    }
    final handle = mode == XrProbeMode.pattern ? null : await target.handle();
    final logPath = await _availability.settings.newLogPath();
    final result = await _availability.api.start(
      handle: handle,
      mode: mode,
      stereo: target.stereo,
      fps: fps ?? target.fps,
      yaw: target.yaw,
      logPath: logPath,
      label: mode == XrProbeMode.pattern ? 'test pattern' : target.label,
    );
    if (!mounted) {
      return;
    }
    if (!result.ok) {
      _show(result.reason ?? '?');
      if (mode != XrProbeMode.pattern) {
        await target.release?.call();
      }
      return;
    }
    _log.info('headset view started: ${mode.name}, log $logPath');
    _started = mode == XrProbeMode.pattern ? null : target;
    setState(() => _active = true);
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    final state = await _availability.api.state();
    if (!mounted) {
      return;
    }
    final status = state.running
        ? [
            state.phase,
            if (state.sessionState.isNotEmpty) state.sessionState,
            if (state.system.isNotEmpty) state.system,
          ].join(', ')
        : [state.phase, if (state.reason.isNotEmpty) state.reason].join(': ');
    setState(() => _status = status);
    if (!state.running) {
      _poll?.cancel();
      _active = false;
      final started = _started;
      _started = null;
      await started?.release?.call();
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _stop() async {
    _poll?.cancel();
    await _availability.api.stop();
    final started = _started;
    _started = null;
    _active = false;
    await started?.release?.call();
    if (mounted) {
      await _refresh();
    }
  }

  void _show(String text) {
    if (!mounted) {
      return;
    }
    setState(() => _status = text);
  }

  Future<void> _on(_Action action) async {
    switch (action) {
      case _Action.sphere:
        await _start(XrProbeMode.sphere);
      case _Action.screen:
        await _start(XrProbeMode.screen);
      case _Action.pattern24:
        await _start(XrProbeMode.pattern, fps: 24);
      case _Action.pattern30:
        await _start(XrProbeMode.pattern, fps: 30);
      case _Action.recenter:
        await _availability.api.recenter();
      case _Action.stop:
        await _stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _availability.settings.enabled,
      builder: (context, enabled, _) {
        if (!enabled || !_compiled || !_availability.windows) {
          return const SizedBox.shrink();
        }
        final modes = widget.target().modes;
        final status = _status;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<_Action>(
              key: const Key('headset_probe_button'),
              tooltip: context.t.headset_probe_button,
              icon: Icon(_active ? Icons.view_in_ar : Icons.view_in_ar_outlined, color: widget.color),
              onSelected: (action) => unawaited(_on(action)),
              itemBuilder: (context) => [
                if (modes.contains(XrProbeMode.sphere))
                  PopupMenuItem(
                    key: const Key('headset_probe_sphere'),
                    value: _Action.sphere,
                    child: Text(context.t.headset_probe_sphere),
                  ),
                if (modes.contains(XrProbeMode.screen))
                  PopupMenuItem(
                    key: const Key('headset_probe_screen'),
                    value: _Action.screen,
                    child: Text(context.t.headset_probe_screen),
                  ),
                PopupMenuItem(
                  key: const Key('headset_probe_pattern24'),
                  value: _Action.pattern24,
                  child: Text(context.t.headset_probe_pattern(fps: 24)),
                ),
                PopupMenuItem(
                  key: const Key('headset_probe_pattern30'),
                  value: _Action.pattern30,
                  child: Text(context.t.headset_probe_pattern(fps: 30)),
                ),
                if (_active) ...[
                  PopupMenuItem(
                    key: const Key('headset_probe_recenter'),
                    value: _Action.recenter,
                    child: Text(context.t.headset_probe_recenter),
                  ),
                  PopupMenuItem(
                    key: const Key('headset_probe_stop'),
                    value: _Action.stop,
                    child: Text(context.t.headset_probe_stop),
                  ),
                ],
              ],
            ),
            if (status != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      context.t.headset_probe_status(status: status),
                      key: const Key('headset_probe_status'),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
