// "Headset view (probe, experimental)" in the video settings of Immuch360 Desktop on Windows (headset_probe.dart): the
// switch, off by default, then, in a build that has the probe, the test pattern in the headset with no video and the
// folder of the probe's logs; in a build without it, "Not in this build of the app".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/video/xr/headset_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:media_kit_video/xr.dart';
import 'package:path/path.dart' as p;

class HeadsetProbeSetting extends StatefulWidget {
  const HeadsetProbeSetting({super.key, this.availability});

  final HeadsetProbeAvailability? availability;

  @override
  State<HeadsetProbeSetting> createState() => _HeadsetProbeSettingState();
}

class _HeadsetProbeSettingState extends State<HeadsetProbeSetting> {
  late final HeadsetProbeAvailability _availability = widget.availability ?? HeadsetProbeAvailability.shared;
  bool? _compiled;
  String? _logFolder;

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

  Future<void> _copyLogFolder() async {
    final folder = _logFolder ??= p.dirname(await _availability.settings.newLogPath());
    await Clipboard.setData(ClipboardData(text: folder));
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_availability.windows) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<bool>(
      valueListenable: _availability.settings.enabled,
      builder: (context, enabled, _) => Column(
        key: const Key('headset_probe_setting'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('headset_probe_setting_switch'),
            value: enabled,
            onChanged: (value) => unawaited(_availability.settings.setEnabled(value)),
            title: Text(context.t.headset_probe_setting_title),
            subtitle: Text(
              _compiled == false ? context.t.headset_probe_not_in_build : context.t.headset_probe_setting_subtitle,
            ),
          ),
          if (enabled && _compiled == true)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  HeadsetProbeButton(
                    availability: _availability,
                    color: Theme.of(context).colorScheme.primary,
                    target: () => HeadsetProbeTarget(handle: () async => null, modes: const [XrProbeMode.pattern]),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: TextButton(
                      key: const Key('headset_probe_copy_logs'),
                      onPressed: () => unawaited(_copyLogFolder()),
                      child: Text(
                        _logFolder == null
                            ? context.t.headset_probe_copy_log_folder
                            : context.t.headset_probe_log_folder(path: _logFolder!),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
