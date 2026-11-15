// "PC VR headset (experimental)" in Settings, Asset Viewer, Videos of Immuch360 Desktop, under the AV2 row
// (headset_view.dart): the switch, on by default; the state line (Windows only for now, with the switch disabled, on
// Linux and macOS; no PC VR runtime found; or the runtime registered); then, while on, matching the refresh rate,
// pausing when the headset is taken off and the test pattern at 24 or 30 frames per second; and, on or off, the folder
// of the headset logs to send back (the crash guard turns the switch off exactly when the logs matter most).
// A Windows build without the plugin's option shows no row: nothing in it could work.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view.dart';
import 'package:immich_mobile/desktop/video/xr/headset_view_service.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class HeadsetViewSetting extends ConsumerStatefulWidget {
  const HeadsetViewSetting({super.key, this.openFolder});

  /// Opens a folder in the system's file manager, replaced by the tests
  final Future<bool> Function(String folder)? openFolder;

  @override
  ConsumerState<HeadsetViewSetting> createState() => _HeadsetViewSettingState();
}

class _HeadsetViewSettingState extends ConsumerState<HeadsetViewSetting> {
  late final HeadsetViewService _service = ref.read(headsetViewServiceProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_service.settings.load().then((_) => _service.refreshRuntime()));
  }

  Future<void> _openLogs() async {
    final folder = await _service.settings.logFolder();
    await (widget.openFolder ?? openFolder)(folder.path);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    if (!_service.windows) {
      return SwitchListTile(
        key: const Key('headset_view_setting_switch'),
        value: false,
        onChanged: null,
        title: Text(t.headset_view_setting_title),
        subtitle: Text(t.headset_view_setting_windows_only, key: const Key('headset_view_setting_state')),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([
        _service,
        _service.settings.enabled,
        _service.settings.matchRefreshRate,
        _service.settings.pauseWhenTakenOff,
      ]),
      builder: (context, _) {
        final runtime = _service.runtime;
        if (runtime == null || !runtime.compiled) {
          return const SizedBox.shrink(key: Key('headset_view_setting_absent'));
        }
        final settings = _service.settings;
        final enabled = settings.enabled.value;
        final state = runtime.registered
            ? t.headset_view_setting_runtime(runtime: headsetRuntimeName(t, runtime))
            : t.headset_view_setting_no_runtime;
        return Column(
          key: const Key('headset_view_setting'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('headset_view_setting_switch'),
              value: enabled,
              onChanged: (value) => unawaited(settings.setEnabled(value)),
              title: Text(t.headset_view_setting_title),
              subtitle: Text('${t.headset_view_setting_subtitle}\n$state'),
            ),
            if (enabled) ...[
              SwitchListTile(
                key: const Key('headset_view_setting_refresh'),
                value: settings.matchRefreshRate.value,
                onChanged: (value) => unawaited(settings.setMatchRefreshRate(value)),
                title: Text(t.headset_view_refresh_title),
                subtitle: Text(t.headset_view_refresh_subtitle),
              ),
              SwitchListTile(
                key: const Key('headset_view_setting_pause'),
                value: settings.pauseWhenTakenOff.value,
                onChanged: (value) => unawaited(settings.setPauseWhenTakenOff(value)),
                title: Text(t.headset_view_pause_title),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  if (enabled && runtime.registered)
                    for (final fps in const [24, 30])
                      TextButton(
                        key: Key('headset_view_pattern_$fps'),
                        onPressed: () => unawaited(_service.startPattern(fps.toDouble(), locale: context.locale)),
                        child: Text(t.headset_view_pattern(fps: fps)),
                      ),
                  if (enabled && runtime.registered && _service.running)
                    TextButton(
                      key: const Key('headset_view_setting_stop'),
                      onPressed: () => unawaited(_service.stop()),
                      child: Text(t.headset_view_stop),
                    ),
                  TextButton(
                    key: const Key('headset_view_open_logs'),
                    onPressed: () => unawaited(_openLogs()),
                    child: Text(t.headset_view_open_logs),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
