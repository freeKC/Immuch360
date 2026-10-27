// The AI settings of the Meta Quest, in the advanced settings (design-final 2026-10-26, sections 3.3, 3.5, 3.7 and 5):
// the switch of the AI features (on by default, off hides every AI button and downloads nothing), the untested switch
// of the Quest 2 and Pro, whether a relief opens in 2.5D (experimental, off: stereo stays the default until FreeKC's
// comfort session), the relief cache with its size and Clear, and the AI components (lot A3b) with their sizes,
// licences and Remove. The 2.5D switch, the cache and the components come with the quest flavour only, the one that
// computes reliefs.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/components_tile.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/relief_button.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('AiReliefSettings');

/// ai-relief in the cache folder of the app, where the immersive viewer keeps the depth maps
Future<Directory> appReliefCacheFolder() async =>
    Directory(p.join((await getTemporaryDirectory()).path, reliefCacheFolderName));

/// Where the relief cache is. Tests replace it.
final reliefCacheFolderProvider = Provider<Future<Directory> Function()>((_) => appReliefCacheFolder);

/// See the top of this file; shown on Horizon OS only
class AiReliefSettings extends HookConsumerWidget {
  const AiReliefSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final enabled = useState(ref.watch(appConfigProvider).aiImmersive.enabled);
    useValueChanged<bool, void>(
      enabled.value,
      (_, _) => unawaited(ref.read(settingsProvider).write(.aiImmersiveEnabled, enabled.value)),
    );
    final olderHeadsets = useState(ref.watch(appConfigProvider).aiImmersive.olderHeadsets);
    useValueChanged<bool, void>(
      olderHeadsets.value,
      (_, _) => unawaited(ref.read(settingsProvider).write(.aiImmersiveOlderHeadsets, olderHeadsets.value)),
    );
    final mesh25d = useState(ref.watch(appConfigProvider).aiImmersive.questMode == ReliefViewMode.mesh25d);
    useValueChanged<bool, void>(
      mesh25d.value,
      (_, _) => unawaited(
        ref
            .read(settingsProvider)
            .write(.aiReliefQuestMode, mesh25d.value ? ReliefViewMode.mesh25d : ReliefViewMode.stereo),
      ),
    );
    final computesReliefs = ref.watch(appFlavorProvider) == questFlavor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(t.ai_immersive_settings_title, style: context.textTheme.titleSmall),
        ),
        SettingsSwitchListTile(
          key: const Key('advanced_settings_ai_enabled'),
          valueNotifier: enabled,
          title: t.ai_immersive_enabled,
          subtitle: t.ai_immersive_enabled_subtitle,
        ),
        SettingsSwitchListTile(
          key: const Key('advanced_settings_ai_older_headsets'),
          valueNotifier: olderHeadsets,
          enabled: enabled.value,
          title: t.ai_immersive_older_headsets,
        ),
        if (computesReliefs) ...[
          SettingsSwitchListTile(
            key: const Key('advanced_settings_ai_relief_25d'),
            valueNotifier: mesh25d,
            enabled: enabled.value,
            title: t.ai_immersive_relief_25d,
            subtitle: t.ai_immersive_relief_25d_subtitle,
          ),
          const ReliefCacheTile(),
          // A relief runs in the immersive viewer, never under the settings: nothing to stop before a removal
          AiComponentsTile(components: ref.watch(reliefComponentsProvider), onCancelConversions: () async {}),
        ],
      ],
    );
  }
}

/// "Relief cache: 12.0 MiB", and Clear, which removes the depth maps and nothing else: a photo shown again computes
/// its relief again
class ReliefCacheTile extends ConsumerStatefulWidget {
  const ReliefCacheTile({super.key});

  @override
  ConsumerState<ReliefCacheTile> createState() => _ReliefCacheTileState();
}

class _ReliefCacheTileState extends ConsumerState<ReliefCacheTile> {
  late final Future<Directory> Function() _folder = ref.read(reliefCacheFolderProvider);

  /// Null until measured
  int? _bytes;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    int bytes;
    try {
      bytes = await reliefCacheBytes(await _folder());
    } catch (error) {
      _log.warning('Could not measure the relief cache: $error');
      bytes = 0;
    }
    if (mounted) {
      setState(() => _bytes = bytes);
    }
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    try {
      final freed = await clearReliefCache(await _folder());
      _log.info('Relief cache cleared: $freed bytes');
    } catch (error) {
      _log.warning('Could not clear the relief cache: $error');
    }
    await _measure();
    if (mounted) {
      setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ListTile(
      key: const Key('ai_relief_cache_tile'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: const Icon(Icons.layers_outlined),
      title: Text(
        context.t.ai_immersive_relief_cache_size(size: formatBytes(bytes ?? 0)),
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      trailing: TextButton(
        key: const Key('ai_relief_cache_clear'),
        onPressed: bytes == null || bytes == 0 || _clearing ? null : () => unawaited(_clear()),
        child: Text(context.t.clear),
      ),
    );
  }
}
