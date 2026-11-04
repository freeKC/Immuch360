// "AV2 videos (experimental)" in the settings of the videos on the computers (store/m2/av2-2026-11-02/
// plan-2026-11-02.md, sections 1.3 and 4): the switch, on by default (the lab rule of 25 October), what it does and what
// it costs the computer, then the AV2 decoder: its version and the space it takes once installed, with "Remove the AV2
// decoder", or the size it will download the first time an AV2 video plays, or "Not in this version of the app" when
// this version does not offer it; and its licence, which opens the texts of the decoder.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('Av2Setting');

class Av2VideoSetting extends HookConsumerWidget {
  const Av2VideoSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = useState(ref.watch(appConfigProvider.select((config) => config.viewer.av2Videos)));
    useValueChanged<bool, void>(on.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.viewerAv2Videos, on.value));
    });
    final decoder = ref.watch(av2DecoderProvider);
    return Column(
      key: const Key('av2_setting'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSwitchListTile(
          key: const Key('av2_setting_switch'),
          valueNotifier: on,
          title: context.t.av2_settings_title,
          subtitle: context.t.av2_settings_description,
        ),
        _Av2DecoderLine(decoder: decoder),
      ],
    );
  }
}

/// The AV2 decoder: installed with its size and Remove, its download to come, or not in this version; its licence
class _Av2DecoderLine extends StatefulWidget {
  const _Av2DecoderLine({required this.decoder});

  final Av2Decoder decoder;

  @override
  State<_Av2DecoderLine> createState() => _Av2DecoderLineState();
}

class _Av2DecoderLineState extends State<_Av2DecoderLine> {
  late Future<void> _loaded = _load();
  bool _removing = false;

  @override
  void didUpdateWidget(_Av2DecoderLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.decoder.service != widget.decoder.service) {
      _loaded = _load();
    }
  }

  Future<void> _load() async {
    try {
      await widget.decoder.service.load();
    } catch (error, stack) {
      _log.warning('the components folder could not be read', error, stack);
    }
  }

  Future<void> _remove() async {
    final platform = widget.decoder.platform;
    if (platform == null) {
      return;
    }
    final t = context.t;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _removing = true);
    try {
      final removal = await widget.decoder.service.removeGroup(platform, AiFeatureGroup.av2);
      final message = switch (removal.outcome) {
        AiRemoveOutcome.removed => null,
        AiRemoveOutcome.nextStart => t.ai_immersive_removed_next_start,
        AiRemoveOutcome.busy => t.ai_immersive_move_busy,
        AiRemoveOutcome.writeFailed => t.ai_immersive_remove_failed,
      };
      if (message != null) {
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() => _removing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final decoder = widget.decoder;
    return FutureBuilder<void>(
      future: _loaded,
      builder: (context, _) => ListenableBuilder(
        listenable: decoder.service,
        builder: (context, _) {
          final t = context.t;
          final component = decoder.component;
          final status = decoder.status;
          final total = status.total;
          final String line;
          if (component == null || !decoder.offered) {
            line = t.ai_immersive_unavailable_build;
          } else if (decoder.isInstalled) {
            line = t.av2_settings_installed(version: decoder.version, size: formatBytes(decoder.diskBytes));
          } else if (status.state == AiComponentState.downloading) {
            line = t.av2_install_progress(
              percent: total == null || total == 0 ? 0 : (status.received * 100 ~/ total).clamp(0, 100),
            );
          } else {
            line = t.av2_settings_not_installed(size: formatBytes(decoder.downloadBytes));
          }
          final secondary = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary);
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(line, key: const Key('av2_setting_decoder'), style: secondary),
                    ),
                    if (decoder.isInstalled)
                      TextButton(
                        key: const Key('av2_setting_remove'),
                        onPressed: _removing ? null : () => unawaited(_remove()),
                        child: Text(t.av2_settings_remove),
                      ),
                  ],
                ),
                if (component != null)
                  TextButton(
                    key: const Key('av2_setting_licence'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                    onPressed: () => unawaited(showAiLicenceDialog(context, component)),
                    child: Text(t.av2_licence, textAlign: TextAlign.start),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
