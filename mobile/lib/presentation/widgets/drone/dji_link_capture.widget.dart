// The capture and play section of the DJI link page. The capture keeps the first bytes of a session and its last ones,
// with the bench said by chips so that the header of an export is never empty; "Play a capture" plays an export of
// this app, or a .bin and its .idx.csv chosen in the picker, through the same pipeline as the cable and in real time.
// Playing is refused while a remote holds the cable: one source at a time.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_advanced.panel.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

class DjiLinkCaptureSection extends ConsumerStatefulWidget {
  const DjiLinkCaptureSection({super.key});

  @override
  ConsumerState<DjiLinkCaptureSection> createState() => _DjiLinkCaptureSectionState();
}

class _DjiLinkCaptureSectionState extends ConsumerState<DjiLinkCaptureSection> {
  /// Anything else the pilot types about the bench; it goes into the header of the export beside the chips
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  DjiLinkNotifier get _notifier => ref.read(djiLinkProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final capture = state.snapshot?.capture;
    final export = state.export;
    final bench = state.bench;
    return Column(
      key: const Key('dji_link_capture'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (capture == null)
          Text(t.dji_link_capture_nothing, style: context.textTheme.bodySmall)
        else ...[
          DjiLinkFact(
            t.dji_link_capture,
            t.dji_link_capture_state(
              bytes: formatHumanReadableBytes(capture.totalBytes, 1),
              records: capture.records,
              dropped: formatHumanReadableBytes(capture.droppedBytes, 1),
            ),
          ),
          Text(
            t.dji_link_capture_kept(
              first: formatHumanReadableBytes(capture.headBytes, 0),
              last: formatHumanReadableBytes(capture.capacityBytes, 0),
            ),
            key: const Key('dji_link_capture_kept'),
            style: context.textTheme.bodySmall,
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            t.dji_link_capture_privacy,
            key: const Key('dji_link_capture_privacy'),
            style: context.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 6),
        _chips(t, 'cable', t.dji_link_bench_cable, DjiLinkBench.cables, bench.cable),
        _chips(t, 'port', t.dji_link_bench_port, DjiLinkBench.ports, bench.port),
        _chips(t, 'remote', t.dji_link_bench_remote, DjiLinkBench.remotes, bench.remote),
        _chips(t, 'aircraft', t.dji_link_bench_aircraft, DjiLinkBench.aircraftStates, bench.aircraft),
        const SizedBox(height: 4),
        TextField(
          key: const Key('dji_link_capture_notes'),
          controller: _notes,
          decoration: InputDecoration(labelText: t.dji_link_capture_note_hint, isDense: true),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: const Key('dji_link_capture_start'),
              onPressed: capture?.recording == true ? null : () => unawaited(_notifier.startCapture()),
              child: Text(t.dji_link_capture_start),
            ),
            OutlinedButton(
              key: const Key('dji_link_capture_stop'),
              onPressed: capture?.recording == true ? () => unawaited(_notifier.stopCapture()) : null,
              child: Text(t.dji_link_capture_stop),
            ),
            FilledButton(
              key: const Key('dji_link_capture_export'),
              // Nothing captured still exports the header: "nothing ever opened" is a result, and the device and its
              // USB environment are what explain it
              onPressed: state.exporting
                  ? null
                  : () => unawaited(_notifier.exportCapture(bench.notes(_notes.text.isEmpty ? null : _notes.text))),
              child: Text(t.dji_link_capture_export),
            ),
            OutlinedButton(
              key: const Key('dji_link_capture_clear'),
              onPressed: (capture?.totalBytes ?? 0) == 0 ? null : () => unawaited(_notifier.clearCapture()),
              child: Text(t.dji_link_capture_clear),
            ),
          ],
        ),
        if (export != null && export.ok && export.headerOnly) ...[
          const SizedBox(height: 6),
          Text(
            t.dji_link_capture_header_only(path: export.headerPath ?? ''),
            key: const Key('dji_link_capture_header_only'),
            style: context.textTheme.bodySmall,
          ),
        ],
        if (export != null && export.ok && export.repeated) ...[
          const SizedBox(height: 6),
          Text(
            t.dji_live_capture_same(name: djiExportName(export.binPath ?? export.headerPath ?? '').$2),
            key: const Key('dji_link_capture_same'),
            style: context.textTheme.bodySmall,
          ),
        ] else if (export != null && export.ok && !export.headerOnly) ...[
          const SizedBox(height: 6),
          Text(
            t.dji_link_capture_exported(path: export.binPath ?? ''),
            key: const Key('dji_link_capture_exported'),
            style: context.textTheme.bodySmall,
          ),
          Text(t.dji_link_capture_digest(digest: export.sha256 ?? ''), style: context.textTheme.bodySmall),
        ],
        if (export != null && !export.ok)
          Text(export.error ?? '', style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error)),
        const SizedBox(height: 12),
        const DjiLinkPlaySection(),
      ],
    );
  }

  Widget _chips(Translations t, String field, String label, List<String> values, String? selected) => Padding(
    padding: const EdgeInsets.only(top: 2),
    child: Row(
      children: [
        SizedBox(width: 80, child: Text(label, style: context.textTheme.bodySmall)),
        Expanded(
          child: Wrap(
            spacing: 6,
            children: [
              for (final value in values)
                ChoiceChip(
                  key: Key('dji_link_bench_${field}_$value'),
                  visualDensity: VisualDensity.compact,
                  label: Text(djiLinkBenchText(t, value)),
                  selected: selected == value,
                  onSelected: (_) => _notifier.toggleBench(field, value),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// "Play a capture": the captures this app can play, the picker, the start second, and what is playing
class DjiLinkPlaySection extends ConsumerStatefulWidget {
  const DjiLinkPlaySection({super.key});

  @override
  ConsumerState<DjiLinkPlaySection> createState() => _DjiLinkPlaySectionState();
}

class _DjiLinkPlaySectionState extends ConsumerState<DjiLinkPlaySection> {
  final _startAt = TextEditingController(text: '0');

  /// "Play in a loop": the end starts the playback again at the same second, for a headset receiving it
  bool _loop = false;

  @override
  void dispose() {
    _startAt.dispose();
    super.dispose();
  }

  DjiLinkNotifier get _notifier => ref.read(djiLinkProvider.notifier);

  /// What is playing, what played to its end, or where a damaged capture stopped the playback
  Widget _sourceLine(Translations t, DjiLinkSource source) {
    final name = source.name ?? '-';
    final seconds = ((source.positionMs ?? 0) / 1000).toStringAsFixed(1);
    final failure = source.failure;
    if (!source.playing && failure != null) {
      return Text(
        t.dji_link_play_failed(name: name, seconds: seconds, kind: failure),
        key: const Key('dji_link_play_failed'),
        style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error),
      );
    }
    return Text(
      (source.playing ? t.dji_link_playing : t.dji_link_played)(name: name, seconds: seconds),
      key: const Key('dji_link_playing'),
      style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  int get _startAtMs => ((double.tryParse(_startAt.text.replaceAll(',', '.')) ?? 0) * 1000).round().clamp(0, 1 << 31);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final source = state.snapshot?.source;
    final busy = state.linkOpen;
    final playError = state.playError;
    return Column(
      key: const Key('dji_link_play'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_play, style: context.textTheme.labelMedium),
        if (source != null && source.replay)
          Padding(padding: const EdgeInsets.only(top: 4), child: _sourceLine(t, source)),
        if (busy)
          Text(t.dji_link_play_busy, key: const Key('dji_link_play_busy'), style: context.textTheme.bodySmall)
        else if (playError != null)
          Text(
            djiLinkPlayErrorText(t, playError),
            key: const Key('dji_link_play_error'),
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
          ),
        if (state.captures.isEmpty && !state.loadingCaptures)
          Text(t.dji_link_play_none, key: const Key('dji_link_play_none'), style: context.textTheme.bodySmall),
        for (final file in state.captures)
          ListTile(
            key: Key('dji_link_capture_file_${file.name}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(file.name, style: context.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
            subtitle: Text(formatHumanReadableBytes(file.bytes, 1), style: context.textTheme.bodySmall),
            trailing: IconButton(
              key: Key('dji_link_play_${file.name}'),
              tooltip: t.dji_link_play,
              icon: const Icon(Icons.play_arrow_rounded),
              onPressed: busy ? null : () => unawaited(_notifier.play(file, startAtMs: _startAtMs, loop: _loop)),
            ),
          ),
        SizedBox(
          width: 220,
          child: TextField(
            key: const Key('dji_link_play_start_at'),
            controller: _startAt,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t.dji_link_play_start_at, isDense: true),
          ),
        ),
        CheckboxListTile(
          key: const Key('dji_link_play_loop'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(t.dji_link_play_loop, style: context.textTheme.bodySmall),
          value: _loop,
          onChanged: (value) => setState(() => _loop = value ?? false),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: const Key('dji_link_play_choose'),
              onPressed: busy ? null : () => unawaited(_notifier.chooseAndPlay(startAtMs: _startAtMs, loop: _loop)),
              child: Text(t.dji_link_play_choose),
            ),
            OutlinedButton(
              key: const Key('dji_link_play_stop'),
              onPressed: source?.replay == true ? () => unawaited(_notifier.stopPlayback()) : null,
              child: Text(t.dji_link_play_stop),
            ),
            IconButton(
              key: const Key('dji_link_play_refresh'),
              tooltip: t.dji_link_play,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => unawaited(_notifier.listCaptures()),
            ),
          ],
        ),
      ],
    );
  }
}

/// The capture section of Diagnostics on a headset (p2/design-final-2026-10-24.md, 5.3): the remote is on the phone, so
/// one sentence says to save the capture there, and "Save a reception record" writes what this headset received and how
/// it decoded it, with a toast and a line under the button that say where it went or why nothing was written
class DjiReceptionRecordSection extends ConsumerWidget {
  const DjiReceptionRecordSection({super.key});

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final outcome = await ref.read(djiLinkProvider.notifier).exportReception();
    if (!context.mounted) {
      return;
    }
    showDjiExportToast(context, outcome, ref.read(djiLinkProvider).export, record: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final export = state.export;
    final small = context.textTheme.bodySmall;
    final path = export?.binPath ?? export?.headerPath;
    final (folder, name) = djiExportName(path ?? '');
    final result = switch (export) {
      null => null,
      DjiLinkExport(ok: false) => t.dji_live_capture_failed,
      DjiLinkExport(nothing: true) => t.dji_live_record_nothing,
      DjiLinkExport(repeated: true) => t.dji_live_capture_same(name: name),
      _ => path == null ? null : t.dji_live_record_saved(folder: folder, name: name),
    };
    return Column(
      key: const Key('dji_link_reception_record'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_capture_headset, key: const Key('dji_link_capture_headset'), style: small),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('dji_link_save_record'),
          icon: const Icon(Icons.save_alt_rounded),
          label: Text(t.dji_live_watch_save_record),
          onPressed: state.exporting ? null : () => unawaited(_save(context, ref)),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(result, key: const Key('dji_link_record_result'), style: small),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t.dji_live_record_privacy, style: small),
        ),
      ],
    );
  }
}
