// The DJI link page (Settings, Advanced, "DJI link diagnostics (experimental)", on by default): what a DJI remote
// controller plugged into this device with a cable sends, and what this device can do about it at all.
//
// It is an instrument, not a cockpit. The first section is the rules and cannot be dismissed. Then: what this device
// can do, where the link stands, what arrives, and the telemetry identifiers, the video probe and the capture. On this
// device the only byte ever written is the liveness probe of the USB transport, once a second, counted here.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_frames.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_safety.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_sticks.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

@RoutePage()
class DjiLinkPage extends ConsumerStatefulWidget {
  const DjiLinkPage({super.key});

  @override
  ConsumerState<DjiLinkPage> createState() => _DjiLinkPageState();
}

class _DjiLinkPageState extends ConsumerState<DjiLinkPage> {
  late final DjiLinkNotifier _notifier;

  /// What the pilot types about the bench; it goes into the header of the export beside the bytes
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(djiLinkProvider.notifier);
    // After the first frame: reading the environment changes the state, which a build under way must not see
    unawaited(Future.microtask(_notifier.pageShown));
  }

  @override
  void dispose() {
    unawaited(_notifier.pageHidden());
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final snapshot = state.snapshot;
    return Scaffold(
      appBar: AppBar(title: Text(t.dji_link_title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const DjiLinkSafetyBanner(),
          _section(t.dji_link_environment, _environment(state)),
          if (state.transportPossible) ...[
            _section(t.dji_link_link, _link(snapshot, state)),
            _section(t.dji_link_traffic, _traffic(snapshot)),
            _section(t.dji_link_telemetry, _telemetry(snapshot)),
            _section(t.dji_link_video, _video(snapshot)),
            _section(t.dji_link_capture, _capture(state, snapshot)),
            _section(t.dji_link_sticks, _sticks(snapshot)),
          ],
          if (state.error case final String error)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(error, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error)),
            ),
        ],
      ),
    );
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );

  String _onOff(bool value) => value ? context.t.dji_link_yes : context.t.dji_link_no;

  Widget _environment(DjiLinkPageState state) {
    final t = context.t;
    final environment = state.environment;
    if (environment == null) {
      // The answers come from the device in a few milliseconds; a spinner that could outlive them would say more than
      // it knows
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('dji_link_environment'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkFact('${environment.deviceManufacturer} ${environment.deviceModel}', environment.androidRelease),
        DjiLinkFact(t.dji_link_environment_build, environment.buildFingerprint),
        DjiLinkFact(t.dji_link_environment_app, '${environment.appVersion} ${environment.flavour}'),
        DjiLinkFact(
          t.dji_link_environment_accessory_feature,
          environment.hasAccessoryFeature ? t.dji_link_present : t.dji_link_absent,
          highlight: true,
        ),
        DjiLinkFact(
          t.dji_link_environment_host_feature,
          environment.hasHostFeature ? t.dji_link_present : t.dji_link_absent,
        ),
        DjiLinkFact(
          t.dji_link_environment_node,
          environment.accessoryNodeExists ? t.dji_link_present : t.dji_link_absent,
        ),
        DjiLinkFact(
          t.dji_link_environment_library,
          environment.futureUsbLibraryPresent ? t.dji_link_present : t.dji_link_absent,
        ),
        DjiLinkFact(t.dji_link_environment_adb, _onOff(environment.adbEnabled)),
        DjiLinkFact(
          t.dji_link_environment_usb_state,
          environment.usbStateKnown
              ? t.dji_link_environment_usb_state_value(
                  connected: _onOff(environment.usbConnected),
                  configured: _onOff(environment.usbConfigured),
                  accessory: _onOff(environment.usbAccessoryMode),
                )
              : t.dji_link_absent,
        ),
        DjiLinkFact(t.dji_link_environment_dji_app, _onOff(environment.djiApplicationInstalled)),
        DjiLinkFact(t.dji_link_environment_accessories, '${environment.accessoriesListed}'),
        if (environment.chargeCurrentMicroAmps case final int current)
          DjiLinkFact(t.dji_link_environment_charge, '$current uA'),
        if (!environment.transportPossible)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.dji_link_no_transport,
              key: const Key('dji_link_no_transport'),
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _link(DjiLinkSnapshot? snapshot, DjiLinkPageState state) {
    final t = context.t;
    if (snapshot == null) {
      return const SizedBox.shrink();
    }
    final accessory = snapshot.accessory;
    final profile = snapshot.profile;
    return Column(
      key: const Key('dji_link_link'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkFact(t.dji_link_state, djiLinkStateText(t, snapshot.state), highlight: true),
        if (_reason(snapshot) case final String reason)
          Text(reason, key: const Key('dji_link_reason'), style: context.textTheme.bodySmall),
        DjiLinkFact(
          t.dji_link_accessory,
          accessory == null
              ? t.dji_link_absent
              : [
                  accessory.manufacturer ?? '-',
                  accessory.model ?? '-',
                  accessory.description ?? '-',
                  accessory.version ?? '-',
                ].join(' | '),
        ),
        DjiLinkFact(
          t.dji_link_profile,
          profile == null ? t.dji_link_support_unknown : djiLinkProfileText(t, profile, accessory),
        ),
        DjiLinkFact(
          t.dji_link_first_byte,
          snapshot.firstByteMs == null ? t.dji_link_never : '${snapshot.firstByteMs} ms',
          highlight: true,
        ),
        DjiLinkFact(
          t.dji_link_probes,
          t.dji_link_probes_value(
            sent: snapshot.probesSent,
            failed: snapshot.probeFailures,
            row: snapshot.consecutiveProbeFailures,
          ),
        ),
        DjiLinkFact(t.dji_link_probe_call, '${snapshot.lastProbeCallMs} ms'),
        if (snapshot.probesHalted)
          Text(
            t.dji_link_probes_halted,
            key: const Key('dji_link_probes_halted'),
            style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        DjiLinkFact(
          t.dji_link_read,
          t.dji_link_read_value(bytes: formatHumanReadableBytes(snapshot.bytesRead, 1), reads: snapshot.reads),
        ),
        DjiLinkFact(
          t.dji_link_written,
          t.dji_link_written_value(bytes: snapshot.bytesWritten, writes: snapshot.writes),
        ),
        DjiLinkFact(t.dji_link_attempts, '${snapshot.attempts}'),
        DjiLinkFact(t.dji_link_opens, '${snapshot.opens}'),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            t.dji_link_quiet_window(seconds: (snapshot.quietWindowMs / 1000).round()),
            style: context.textTheme.bodySmall,
          ),
        ),
        if (profile != null) ...[
          const SizedBox(height: 6),
          Text(t.dji_link_capabilities, style: context.textTheme.labelMedium),
          for (final capability in profile.capabilities)
            DjiLinkFact(
              djiLinkCapabilityText(t, capability.name),
              [_support(capability.support), ?capability.provenance].join(' '),
            ),
        ],
        const SizedBox(height: 6),
        OutlinedButton(
          key: const Key('dji_link_retry'),
          onPressed: () => unawaited(_notifier.retry()),
          child: Text(t.dji_link_retry),
        ),
      ],
    );
  }

  /// The sentence for the reason of the state, with the one technical word the native side may add to it
  String? _reason(DjiLinkSnapshot snapshot) {
    final reason = snapshot.reason;
    if (reason == null) {
      return snapshot.detail;
    }
    final sentence = djiLinkReasonText(context.t, reason);
    return snapshot.detail == null ? sentence : '$sentence (${snapshot.detail})';
  }

  String _support(DjiLinkSupport support) => switch (support) {
    DjiLinkSupport.unknown => context.t.dji_link_support_unknown,
    DjiLinkSupport.unsupported => context.t.dji_link_support_unsupported,
    DjiLinkSupport.supported => context.t.dji_link_support_supported,
  };

  Widget _traffic(DjiLinkSnapshot? snapshot) {
    final t = context.t;
    if (snapshot == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkChannelsTable(channels: snapshot.channels),
        const SizedBox(height: 8),
        Text(t.dji_link_counters, style: context.textTheme.labelMedium),
        DjiLinkCountersBlock(counters: snapshot.counters),
        const SizedBox(height: 8),
        Text(t.dji_link_crc, style: context.textTheme.labelMedium),
        DjiLinkCrcBlock(crc: snapshot.crc),
        const SizedBox(height: 8),
        Text(t.dji_link_frame_list, style: context.textTheme.labelMedium),
        DjiLinkFramesList(frames: snapshot.frames),
      ],
    );
  }

  Widget _telemetry(DjiLinkSnapshot? snapshot) {
    final t = context.t;
    final rows = snapshot?.telemetry ?? const <DjiLinkTelemetryRow>[];
    return Column(
      key: const Key('dji_link_telemetry'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_telemetry_note, style: context.textTheme.bodySmall),
        const SizedBox(height: 6),
        if (rows.isEmpty)
          Text(t.dji_link_no_frames, style: context.textTheme.bodySmall)
        else
          for (final row in rows)
            DjiLinkFact(
              [
                t.dji_link_message_id(commandSet: '${row.commandSet}', commandId: '${row.commandId}'),
                ?row.name,
              ].join(' '),
              '${t.dji_link_telemetry_rate(count: row.count, bodyLength: '${row.lastLength}', rate: row.ratePerSecond.toStringAsFixed(1))} '
              '${row.preview}',
            ),
      ],
    );
  }

  Widget _video(DjiLinkSnapshot? snapshot) {
    final t = context.t;
    final video = snapshot?.video;
    if (video == null) {
      return const SizedBox.shrink();
    }
    final verdict = switch (video.verdict) {
      DjiLinkProbeVerdict.noData => t.dji_link_video_verdict_no_data,
      DjiLinkProbeVerdict.noStartCodes => t.dji_link_video_verdict_no_start_codes,
      DjiLinkProbeVerdict.startCodesSeen => t.dji_link_video_verdict_start_codes,
    };
    return Column(
      key: const Key('dji_link_video'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(verdict, style: context.textTheme.bodySmall),
        const SizedBox(height: 4),
        DjiLinkFact(t.dji_link_video_payloads, '${video.payloads}'),
        DjiLinkFact(t.dji_link_video_start_codes, '${video.startCodesSeen}'),
        DjiLinkFact(t.dji_link_video_unit_types, video.unitTypes.isEmpty ? '-' : video.unitTypes),
        for (final channel in video.channels)
          DjiLinkFact(
            '${t.dji_link_channel} ${channel.channel}',
            t.dji_link_video_fragments(
              fragments: channel.fragments,
              bytes: formatHumanReadableBytes(channel.bytes, 1),
              largest: channel.largestFragment,
            ),
          ),
      ],
    );
  }

  Widget _capture(DjiLinkPageState state, DjiLinkSnapshot? snapshot) {
    final t = context.t;
    final capture = snapshot?.capture;
    final export = state.export;
    return Column(
      key: const Key('dji_link_capture'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (capture == null)
          Text(t.dji_link_capture_nothing, style: context.textTheme.bodySmall)
        else
          DjiLinkFact(
            t.dji_link_capture,
            t.dji_link_capture_state(
              bytes: formatHumanReadableBytes(capture.totalBytes, 1),
              records: capture.records,
              dropped: formatHumanReadableBytes(capture.droppedBytes, 1),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            t.dji_link_capture_privacy,
            key: const Key('dji_link_capture_privacy'),
            style: context.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 6),
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
                  : () => unawaited(
                      _notifier.exportCapture(DjiLinkExportNotes(note: _notes.text.isEmpty ? null : _notes.text)),
                    ),
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
        if (export != null && export.ok && !export.headerOnly) ...[
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
      ],
    );
  }

  Widget _sticks(DjiLinkSnapshot? snapshot) {
    final sticks = snapshot?.sticks;
    if (sticks == null) {
      return const SizedBox.shrink();
    }
    return DjiLinkSticksDisplay(sticks: sticks);
  }
}
