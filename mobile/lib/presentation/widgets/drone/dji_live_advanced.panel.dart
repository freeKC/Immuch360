// Advanced, on the live screen of the phone (p2/design-final-2026-10-24.md, 3.6 and 4): opening the screen when the
// remote is plugged in, a capture for a bug report with a toast that names it, a saved capture to play, the safety
// notice again, Diagnostics, the values the gate keeps out of the picture (the proven ones with their labels, the
// likely ones under "Not confirmed yet" with a question mark), and the obstacle ring as the gate offers it. The
// capture and Diagnostics stay one tap away: they are what a bug report is made of.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_capture.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_relay_quality.widget.dart';
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
            onChanged: (on) {
              unawaited(notifier.setOpenOnPlug(on));
              // Answered here: the plug step never asks again
              unawaited(ref.read(djiLiveMemoryProvider).write(StoreKey.djiLiveOfferAnswered, true));
            },
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
        const DjiRelayQualitySection(),
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

/// A distance of the ring as the steppers write it: 3.0 m, 0.75 m
String djiObstacleDistanceText(Translations t, int cm) =>
    t.dji_live_obstacle_distance(distance: (cm / 100).toStringAsFixed(cm % 10 == 0 ? 1 : 2));

/// "Obstacle ring" in Advanced (p2/design-obstacle-ring-2026-10-25.md, 6.1): one line while the gate does not offer it;
/// while its data is likely, a switch on by default (FreeKC's rule of 25 October) that says it is not confirmed; once
/// offered, "Glow from" and "Strong glow from", the side as its own gate row allows (off by default while likely), the
/// sound and its test, the vibration on a phone that has one, the distance by the glow, and the shape (a circle around
/// the centre by default, or a frame at the edges). Each says what is on by default. "Show a sample" is always there,
/// refused while the motors run. The lines that say it only informs and that no glow is not a clear way close the
/// section.
class DjiObstacleSection extends ConsumerStatefulWidget {
  const DjiObstacleSection({super.key, this.gates = djiLiveGates});

  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  ConsumerState<DjiObstacleSection> createState() => _DjiObstacleSectionState();
}

class _DjiObstacleSectionState extends ConsumerState<DjiObstacleSection> {
  /// The media volume was at zero when the section was last shown or the sound last played
  bool _volumeOff = false;

  /// This phone can vibrate: "Vibrate with the tick" shows only then
  bool _vibrator = false;

  /// The last "Show a sample" was refused: the motors run
  bool _sampleRefused = false;

  @override
  void initState() {
    super.initState();
    unawaited(Future.microtask(_checkVolume));
    unawaited(Future.microtask(_checkVibrator));
  }

  Future<void> _checkVolume() async {
    final off = await ref.read(djiObstacleSettingsProvider.notifier).mediaVolumeOff();
    if (mounted) {
      setState(() => _volumeOff = off);
    }
  }

  Future<void> _checkVibrator() async {
    final vibrator = await ref.read(djiObstacleSettingsProvider.notifier).hasVibrator();
    if (mounted) {
      setState(() => _vibrator = vibrator);
    }
  }

  Future<void> _playTest() async {
    await ref.read(djiObstacleSettingsProvider.notifier).playTest();
    await _checkVolume();
  }

  Future<void> _sample() async {
    final shown = await ref.read(djiObstacleSettingsProvider.notifier).showSample();
    if (mounted) {
      setState(() => _sampleRefused = !shown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final offer = djiObstacleOffer(gates: widget.gates);
    final sideOffer = djiObstacleSideOffer(gates: widget.gates);
    final settings = ref.watch(djiObstacleSettingsProvider);
    final notifier = ref.read(djiObstacleSettingsProvider.notifier);
    final flying = ref.watch(djiLiveFrameProvider.select((frame) => frame?.motorsOn ?? false));
    final offered = settings.offered(offer);
    final nearMaxCm = math.min(djiObstacleNearMaxCm, settings.farCm - djiObstacleGapCm);
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
            DjiObstacleStepper(
              name: 'far',
              label: t.dji_live_obstacle_far,
              value: djiObstacleDistanceText(t, settings.farCm),
              note: t.dji_live_obstacle_far_note,
              onLess: settings.farCm > djiObstacleFarMinCm
                  ? () => unawaited(notifier.setFar(settings.farCm - djiObstacleFarStepCm))
                  : null,
              onMore: settings.farCm < djiObstacleFarMaxCm
                  ? () => unawaited(notifier.setFar(settings.farCm + djiObstacleFarStepCm))
                  : null,
            ),
            DjiObstacleStepper(
              name: 'near',
              label: t.dji_live_obstacle_near,
              value: djiObstacleDistanceText(t, settings.nearCm),
              onLess: settings.nearCm > djiObstacleNearMinCm
                  ? () => unawaited(notifier.setNear(settings.nearCm - djiObstacleNearStepCm))
                  : null,
              onMore: settings.nearCm < nearMaxCm
                  ? () => unawaited(notifier.setNear(settings.nearCm + djiObstacleNearStepCm))
                  : null,
            ),
            if (sideOffer == DjiObstacleSideOffer.test)
              SwitchListTile(
                key: const Key('dji_live_obstacle_side_test'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.dji_live_obstacle_side_test),
                subtitle: Text(t.dji_live_obstacle_side_test_note, style: small),
                value: settings.sideTest,
                onChanged: (on) => unawaited(notifier.setSideTest(on)),
              ),
            if (sideOffer == DjiObstacleSideOffer.proven)
              SwitchListTile(
                key: const Key('dji_live_obstacle_side'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.dji_live_obstacle_side),
                subtitle: Text(t.dji_live_obstacle_side_note, style: small),
                value: !settings.sideOff,
                onChanged: (on) => unawaited(notifier.setSideShown(on)),
              ),
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
            if (_vibrator)
              SwitchListTile(
                key: const Key('dji_live_obstacle_haptic'),
                contentPadding: EdgeInsets.zero,
                title: Text(t.dji_live_obstacle_haptic),
                subtitle: Text(t.dji_live_obstacle_haptic_note, style: small),
                value: settings.hapticOn,
                onChanged: (on) => unawaited(notifier.setHaptic(on)),
              ),
            SwitchListTile(
              key: const Key('dji_live_obstacle_numbers'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.dji_live_obstacle_numbers),
              subtitle: Text(t.dji_live_obstacle_numbers_note, style: small),
              value: settings.numbersOn,
              onChanged: (on) => unawaited(notifier.setNumbers(on)),
            ),
            DjiObstacleShapeChoice(frame: settings.frame, onFrame: (frame) => unawaited(notifier.setFrame(frame))),
          ],
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('dji_live_obstacle_sample'),
            icon: const Icon(Icons.blur_on_rounded),
            label: Text(t.dji_live_obstacle_sample),
            onPressed: flying ? null : () => unawaited(_sample()),
          ),
        ),
        Text(
          flying || _sampleRefused ? t.dji_live_obstacle_sample_flying : t.dji_live_obstacle_sample_note,
          key: const Key('dji_live_obstacle_sample_note'),
          style: small,
        ),
        Text(t.dji_live_obstacle_info_only, key: const Key('dji_live_obstacle_info_only'), style: small),
        Text(t.dji_live_obstacle_limits, key: const Key('dji_live_obstacle_limits'), style: small),
      ],
    );
  }
}

/// "Obstacle indicator shape": the circle around the centre (the default) or the frame at the edges
class DjiObstacleShapeChoice extends StatelessWidget {
  const DjiObstacleShapeChoice({super.key, required this.frame, required this.onFrame});

  final bool frame;
  final ValueChanged<bool> onFrame;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      key: const Key('dji_live_obstacle_shape'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.dji_live_obstacle_shape, style: context.textTheme.bodyLarge),
          Text(t.dji_live_obstacle_shape_note, style: context.textTheme.bodySmall),
          const SizedBox(height: 6),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                label: Text(t.dji_live_obstacle_shape_circle, key: const Key('dji_live_obstacle_shape_circle')),
              ),
              ButtonSegment(
                value: true,
                label: Text(t.dji_live_obstacle_shape_frame, key: const Key('dji_live_obstacle_shape_frame')),
              ),
            ],
            selected: {frame},
            onSelectionChanged: (selected) => onFrame(selected.first),
          ),
        ],
      ),
    );
  }
}

/// A distance of the ring with its two buttons: less and more, each off at its end
class DjiObstacleStepper extends StatelessWidget {
  const DjiObstacleStepper({
    super.key,
    required this.name,
    required this.label,
    required this.value,
    this.note,
    this.onLess,
    this.onMore,
  });

  /// far or near, for the keys
  final String name;
  final String label;
  final String value;
  final String? note;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    return Padding(
      key: Key('dji_live_obstacle_$name'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.textTheme.bodyLarge),
                if (note != null) Text(note, style: context.textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            key: Key('dji_live_obstacle_${name}_less'),
            tooltip: context.t.dji_live_obstacle_closer(name: label),
            icon: const Icon(Icons.remove_rounded),
            onPressed: onLess,
          ),
          Text(
            value,
            key: Key('dji_live_obstacle_${name}_value'),
            style: context.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          IconButton(
            key: Key('dji_live_obstacle_${name}_more'),
            tooltip: context.t.dji_live_obstacle_farther(name: label),
            icon: const Icon(Icons.add_rounded),
            onPressed: onMore,
          ),
        ],
      ),
    );
  }
}
