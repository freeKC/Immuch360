// Advanced, on the live screen of the phone (p2/design-ux-phone-2026-10-24.md, 3.6): opening the screen when the
// remote is plugged in, a capture for a bug report, a saved capture to play, the safety notice again, Diagnostics, and
// the values the gate keeps out of the picture: the proven ones with their labels, the likely ones with a question mark
// in theirs. The capture and Diagnostics stay one tap away: they are what a bug report is made of.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_capture.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';

class DjiLiveAdvancedPanel extends ConsumerWidget {
  const DjiLiveAdvancedPanel({super.key, required this.onSafety, required this.onDiagnostics});

  final VoidCallback onSafety;
  final VoidCallback onDiagnostics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final notifier = ref.read(djiLinkProvider.notifier);
    final small = context.textTheme.bodySmall;
    final export = state.export;
    final values = djiLiveValues(t, state.snapshot?.telemetryValues, DjiLivePlace.advanced);
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
          onTap: () => unawaited(notifier.exportForBugReport()),
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
        if (values.isEmpty)
          Text(t.dji_link_flight_none, key: const Key('dji_live_values_none'), style: small)
        else
          for (final value in values)
            DjiLinkFact(value.label, value.value, key: Key('dji_live_advanced_value_${value.field.name}')),
        if (state.environment?.djiApplicationInstalled ?? false) ...[
          const SizedBox(height: 12),
          Text(t.dji_live_to_dji_fly, key: const Key('dji_live_to_dji_fly'), style: small),
        ],
      ],
    );
  }
}
