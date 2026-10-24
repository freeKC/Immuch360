// Advanced, on the live screen of the phone (p2/design-final-2026-10-24.md, 3.6 and 4): opening the screen when the
// remote is plugged in, a capture for a bug report with a toast that names it, a saved capture to play, the safety
// notice again, Diagnostics, the values the gate keeps out of the picture (the proven ones with their labels, the
// likely ones under "Not confirmed yet" with a question mark), and the obstacle alert as the gate offers it. The
// capture and Diagnostics stay one tap away: they are what a bug report is made of.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_capture.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

/// The words of the toast of an export, null when there is nothing to say (a tap while one ran)
String? djiExportToastText(
  Translations t,
  DjiLinkExportOutcome outcome,
  DjiLinkExport? export, {
  bool record = false,
}) {
  final path = export?.binPath ?? export?.headerPath ?? '';
  final (folder, name) = djiExportName(path);
  return switch (outcome) {
    DjiLinkExportOutcome.saved => record
        ? t.dji_live_record_saved(folder: folder, name: name)
        : t.dji_live_capture_saved(folder: folder, name: name),
    DjiLinkExportOutcome.repeated => t.dji_live_capture_same(name: name),
    DjiLinkExportOutcome.nothing => record ? t.dji_live_record_nothing : t.dji_live_capture_nothing,
    DjiLinkExportOutcome.failed => t.dji_live_capture_failed,
    DjiLinkExportOutcome.busy => null,
  };
}

/// A floating toast of four seconds over the bottom of the screen, with the file's name or why nothing was written
void showDjiExportToast(
  BuildContext context,
  DjiLinkExportOutcome outcome,
  DjiLinkExport? export, {
  bool record = false,
}) {
  final text = djiExportToastText(context.t, outcome, export, record: record);
  if (text == null) {
    return;
  }
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      key: const Key('dji_live_export_toast'),
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ),
  );
}

class DjiLiveAdvancedPanel extends ConsumerWidget {
  const DjiLiveAdvancedPanel({
    super.key,
    required this.onSafety,
    required this.onDiagnostics,
    this.gates = djiLiveGates,
  });

  final VoidCallback onSafety;
  final VoidCallback onDiagnostics;
  final Map<DjiLiveField, DjiLiveGate> gates;

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(djiLinkProvider.notifier);
    final outcome = await notifier.exportForBugReport();
    if (!context.mounted) {
      return;
    }
    showDjiExportToast(context, outcome, ref.read(djiLinkProvider).export);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final notifier = ref.read(djiLinkProvider.notifier);
    final frame = ref.watch(djiLiveFrameProvider);
    final small = context.textTheme.bodySmall;
    final export = state.export;
    final values = djiLiveValues(t, frame, DjiLivePlace.advanced, gates: gates);
    final proven = values.where((value) => !djiLiveIsLikely(value.field, gates: gates)).toList();
    final likely = values.where((value) => djiLiveIsLikely(value.field, gates: gates)).toList();
    return ListView(
      key: const Key('dji_live_advanced_panel'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(t.dji_live_advanced, style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        if (state.transportPossible)
          SwitchListTile(
            key: const Key('dji_live_open_on_plug'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.dji_live_open_on_plug),
            subtitle: Text(t.dji_live_open_on_plug_note, style: small),
            value: state.openOnPlug,
            onChanged: (on) => unawaited(notifier.setOpenOnPlug(on)),
          ),
        ListTile(
          key: const Key('dji_live_save_capture'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.save_alt_rounded),
          title: Text(t.dji_live_save_capture),
          enabled: !state.exporting,
          onTap: () => unawaited(_save(context, ref)),
        ),
        if (export != null && export.ok && export.headerOnly)
          Text(
            t.dji_link_capture_header_only(path: export.headerPath ?? ''),
            key: const Key('dji_live_capture_header_only'),
            style: small,
          ),
        if (export != null && export.ok && !export.headerOnly)
          Text(
            t.dji_link_capture_exported(path: export.binPath ?? ''),
            key: const Key('dji_live_capture_exported'),
            style: small,
          ),
        if (export != null && !export.ok)
          Text(export.error ?? '', style: small?.copyWith(color: context.colorScheme.error)),
        Text(t.dji_link_capture_privacy, style: small),
        ExpansionTile(
          key: const Key('dji_live_play_capture'),
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.play_circle_outline_rounded),
          title: Text(t.dji_live_play_capture),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          onExpansionChanged: (open) {
            if (open) {
              unawaited(notifier.listCaptures());
            }
          },
          children: const [DjiLinkPlaySection()],
        ),
        ListTile(
          key: const Key('dji_live_safety_again'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.warning_amber_rounded),
          title: Text(t.dji_live_safety_again),
          onTap: onSafety,
        ),
        ListTile(
          key: const Key('dji_live_diagnostics'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.analytics_outlined),
          title: Text(t.dji_live_diagnostics),
          subtitle: Text(t.dji_live_diagnostics_note, style: small),
          onTap: onDiagnostics,
        ),
        const SizedBox(height: 8),
        Text(t.dji_live_values, style: context.textTheme.labelLarge),
        Text(t.dji_live_values_note, style: small),
        Text(
          t.dji_link_flight_view_fly_note,
          style: small?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error),
        ),
        Text(t.dji_live_no_dji_warnings, key: const Key('dji_live_no_dji_warnings'), style: small),
        if (values.isEmpty)
          Text(t.dji_link_flight_none, key: const Key('dji_live_values_none'), style: small)
        else
          for (final value in proven)
            DjiLinkFact(value.label, value.value, key: Key('dji_live_advanced_value_${value.field.name}')),
        if (likely.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            t.dji_live_values_unconfirmed,
            key: const Key('dji_live_values_unconfirmed'),
            style: context.textTheme.labelMedium,
          ),
          for (final value in likely)
            DjiLinkFact(value.label, value.value, key: Key('dji_live_advanced_value_${value.field.name}')),
        ],
        if (djiLiveFlightValuesPending(gates: gates))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(t.dji_live_values_pending, key: const Key('dji_live_values_pending'), style: small),
          ),
        const SizedBox(height: 12),
        DjiObstacleSection(gates: gates),
        if (state.environment?.djiApplicationInstalled ?? false) ...[
          const SizedBox(height: 12),
          Text(t.dji_live_to_dji_fly, key: const Key('dji_live_to_dji_fly'), style: small),
        ],
      ],
    );
  }
}

/// "Obstacle alert" in Advanced (p2/design-final-2026-10-24.md, 4.4 and 4.7): one line while the gate does not offer
/// it; while its data is likely, a switch off by default that says it is not confirmed; once proven, its sound. The
/// lines that say it only informs and that no alert is not a clear way are there whenever it is offered.
class DjiObstacleSection extends ConsumerStatefulWidget {
  const DjiObstacleSection({super.key, this.gates = djiLiveGates});

  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  ConsumerState<DjiObstacleSection> createState() => _DjiObstacleSectionState();
}

class _DjiObstacleSectionState extends ConsumerState<DjiObstacleSection> {
  /// The media volume was at zero when the section was last shown or the sound last played
  bool _volumeOff = false;

  @override
  void initState() {
    super.initState();
    unawaited(Future.microtask(_checkVolume));
  }

  Future<void> _checkVolume() async {
    final off = await ref.read(djiObstacleSettingsProvider.notifier).mediaVolumeOff();
    if (mounted) {
      setState(() => _volumeOff = off);
    }
  }

  Future<void> _playTest() async {
    await ref.read(djiObstacleSettingsProvider.notifier).playTest();
    await _checkVolume();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final offer = djiObstacleOffer(gates: widget.gates);
    final settings = ref.watch(djiObstacleSettingsProvider);
    final notifier = ref.read(djiObstacleSettingsProvider.notifier);
    final offered = settings.offered(offer);
    return Column(
      key: const Key('dji_live_obstacle_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_live_obstacle_title, style: context.textTheme.labelLarge),
        if (offer == DjiObstacleOffer.none)
          Text(t.dji_live_obstacle_unoffered, key: const Key('dji_live_obstacle_unoffered'), style: small)
        else ...[
          if (offer == DjiObstacleOffer.test)
            SwitchListTile(
              key: const Key('dji_live_obstacle_test'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.dji_live_obstacle_test),
              subtitle: Text(t.dji_live_obstacle_test_note, style: small),
              value: settings.alertOn,
              onChanged: (on) => unawaited(notifier.setAlert(on)),
            ),
          if (offered) ...[
            SwitchListTile(
              key: const Key('dji_live_obstacle_sound'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.dji_live_obstacle_sound),
              subtitle: Text(t.dji_live_obstacle_sound_note, style: small),
              value: settings.soundOn,
              onChanged: (on) => unawaited(notifier.setSound(on)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('dji_live_obstacle_sound_test'),
                icon: const Icon(Icons.volume_up_rounded),
                label: Text(t.dji_live_obstacle_sound_test),
                onPressed: () => unawaited(_playTest()),
              ),
            ),
            if (_volumeOff)
              Text(
                t.dji_live_media_volume_off,
                key: const Key('dji_live_media_volume_off'),
                style: small?.copyWith(color: context.colorScheme.error),
              ),
          ],
          Text(t.dji_live_obstacle_info_only, key: const Key('dji_live_obstacle_info_only'), style: small),
          Text(t.dji_live_obstacle_limits, key: const Key('dji_live_obstacle_limits'), style: small),
        ],
      ],
    );
  }
}
