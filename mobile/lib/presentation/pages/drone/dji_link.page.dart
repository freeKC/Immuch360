// The DJI link page (Settings, Advanced, "DJI link diagnostics (experimental)", on by default): what a DJI remote
// controller plugged into this device with a cable sends, and what this device can do about it at all.
//
// It is an instrument, not a cockpit. The first section is the rules and cannot be dismissed. Then: what this device
// can do, where the link stands, the live picture of the drone's camera, the flight and battery values, what arrives,
// the telemetry identifiers, the capture and the player of a capture, and the sticks. On this device the only byte
// ever written is the liveness probe of the USB transport, once a second, counted here. A device that cannot be a USB
// accessory (a headset without the feature) still shows the picture and the values of a capture being played, which
// measures its decoder with no remote at all.
//
// Stage 2b: a phone sends the picture and the values it receives to Immuch360 on a headset of the same network ("Send
// to a headset"), and a device without the accessory feature receives them ("Receive from a phone"), with the
// observer note and "Watching only" always on top, the delay from the phone under the picture, and on Horizon OS the
// flight view. Nothing on either page reaches the remote.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_capture.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_flight.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_frames.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_observer.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_receive.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_safety.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_send.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_sticks.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

@RoutePage()
class DjiLinkPage extends ConsumerStatefulWidget {
  const DjiLinkPage({super.key});

  @override
  ConsumerState<DjiLinkPage> createState() => _DjiLinkPageState();
}

class _DjiLinkPageState extends ConsumerState<DjiLinkPage> {
  late final DjiLinkNotifier _notifier;
  late final DjiRelayNotifier _relay;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(djiLinkProvider.notifier);
    _relay = ref.read(djiRelayProvider.notifier);
    // After the first frame: reading the environment changes the state, which a build under way must not see
    unawaited(Future.microtask(_notifier.pageShown));
    unawaited(Future.microtask(_relay.loadCode));
    unawaited(Future.microtask(() => _relay.setPageVisible(true)));
  }

  @override
  void dispose() {
    // The relay keeps sending without the page; only the screen is no longer kept on for it
    unawaited(_relay.setPageVisible(false));
    unawaited(_notifier.pageHidden());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final snapshot = state.snapshot;
    // "Send to a headset" is for phones, and hidden while this device receives: a received stream is never relayed
    final receiving = snapshot?.source?.relay ?? false;
    final sends = state.environment?.flavour == 'phone' && !receiving;
    return Scaffold(
      appBar: AppBar(title: Text(t.dji_link_title)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const DjiLinkSafetyBanner(),
          if (state.transportPossible) ...[
            _section(t.dji_link_environment, _environment(state)),
            _section(t.dji_link_link, _link(snapshot, state)),
            if (sends) _section(t.dji_link_relay, const DjiLinkSendSection()),
            _section(t.dji_link_video, _video(snapshot)),
            _section(t.dji_link_flight, DjiLinkFlightSection(telemetry: snapshot?.telemetryValues)),
            _section(t.dji_link_traffic, _traffic(snapshot)),
            _section(t.dji_link_telemetry, _telemetry(snapshot)),
            _section(t.dji_link_capture, const DjiLinkCaptureSection()),
            _section(t.dji_link_sticks, _sticks(snapshot)),
          ] else if (state.environment != null) ...[
            // No cable path here (a headset, an emulator): the picture of a phone's relay, or of a capture played here,
            // which measures this device's decoder with no remote at all
            const DjiLinkObserverNote(),
            _section(t.dji_link_receive, const DjiLinkReceiveSection()),
            _section(t.dji_link_video, _receivedVideo(snapshot)),
            _section(t.dji_link_flight, DjiLinkFlightSection(telemetry: snapshot?.telemetryValues)),
            _section(t.dji_link_environment, _environment(state)),
            _section(t.dji_link_play, const DjiLinkPlaySection()),
            if (sends) _section(t.dji_link_relay, const DjiLinkSendSection()),
          ] else
            _section(t.dji_link_environment, _environment(state)),
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
        if (snapshot.lastAccessory case final DjiLinkAccessory last)
          DjiLinkFact(
            t.dji_link_last_accessory,
            [last.manufacturer ?? '-', last.model ?? '-', last.description ?? '-', last.version ?? '-'].join(' | '),
          ),
        const SizedBox(height: 6),
        _hardware(snapshot, state),
        if (profile != null) ...[
          const SizedBox(height: 6),
          Text(t.dji_link_capabilities, style: context.textTheme.labelMedium),
          for (final capability in profile.capabilities)
            DjiLinkFact(
              djiLinkCapabilityText(t, capability.name),
              [_support(capability.support), ?_provenance(capability)].join(', '),
            ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            t.dji_link_usb_mode_hint,
            key: const Key('dji_link_usb_mode_hint'),
            style: context.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 6),
        OutlinedButton(
          key: const Key('dji_link_retry'),
          onPressed: () => unawaited(_notifier.retry()),
          child: Text(t.dji_link_retry),
        ),
      ],
    );
  }

  /// "Your hardware": the starting profiles, kept for the accessory strings in use or the last ones seen
  Widget _hardware(DjiLinkSnapshot snapshot, DjiLinkPageState state) {
    final t = context.t;
    final hasStrings = snapshot.accessory != null || snapshot.lastAccessory != null;
    final bound = snapshot.boundProfileId;
    final ids = state.profiles.map((profile) => profile.id).toSet();
    return Column(
      key: const Key('dji_link_hardware'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_hardware, style: context.textTheme.labelMedium),
        if (!hasStrings)
          Text(t.dji_link_hardware_no_strings, style: context.textTheme.bodySmall)
        else
          DropdownButton<String?>(
            key: const Key('dji_link_hardware_choice'),
            isExpanded: true,
            value: ids.contains(bound) ? bound : null,
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(t.dji_link_hardware_none)),
              for (final profile in state.profiles)
                DropdownMenuItem<String?>(
                  value: profile.id,
                  child: Text(djiLinkProfileText(t, profile, null), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) => unawaited(_notifier.bindProfile(id)),
          ),
        Text(t.dji_link_hardware_note, style: context.textTheme.bodySmall),
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

  /// Where an answer comes from. An answer holds on the device and flavour it was verified on, and the native side
  /// reports it unknown anywhere else (the headset build of the same phone included): the line then names the one
  /// device it was verified on, so that a phone result is never read as this device's.
  String? _provenance(DjiLinkCapability capability) {
    final t = context.t;
    final device = capability.observedOn;
    final date = capability.observedDate ?? '-';
    if (device != null) {
      return capability.support == DjiLinkSupport.unknown
          ? t.dji_link_verified_elsewhere(device: device, date: date)
          : t.dji_link_verified_on(device: device, date: date);
    }
    final provenance = capability.provenance;
    return provenance == null ? null : t.dji_link_observed_offline(observation: provenance);
  }

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
                if (row.name != null) djiLinkMessageName(t, row.name!),
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
    final verdict = switch (video?.verdict) {
      null || DjiLinkProbeVerdict.noData => t.dji_link_video_verdict_no_data,
      DjiLinkProbeVerdict.noStartCodes => t.dji_link_video_verdict_no_start_codes,
      DjiLinkProbeVerdict.startCodesSeen => t.dji_link_video_verdict_start_codes,
      DjiLinkProbeVerdict.h265 => t.dji_link_video_verdict_h265,
      DjiLinkProbeVerdict.h264 => t.dji_link_video_verdict_h264,
    };
    return Column(
      key: const Key('dji_link_video'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkVideoPanel(decode: snapshot?.videoDecode),
        const SizedBox(height: 8),
        Text(verdict, key: const Key('dji_link_video_verdict'), style: context.textTheme.bodySmall),
        if (video != null) ...[
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
      ],
    );
  }

  /// The picture of a device that receives or plays: the panel, the delay from the phone, and the flight view button
  Widget _receivedVideo(DjiLinkSnapshot? snapshot) {
    final t = context.t;
    final receiving = snapshot?.relayReceiving;
    final decode = snapshot?.videoDecode;
    final horizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final relay = ref.watch(djiRelayProvider);
    final flowing = receiving != null && receiving.state == DjiRelayReceiveState.receiving && djiLinkPictureFlows(decode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _video(snapshot),
        if (receiving != null && receiving.state != DjiRelayReceiveState.idle) ...[
          const SizedBox(height: 8),
          Text(t.dji_link_latency, style: context.textTheme.labelMedium),
          DjiLinkLatencyBlock(receiving: receiving, decode: decode),
        ],
        if (horizonOs) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('dji_link_flight_view_open'),
            icon: const Icon(Icons.view_in_ar_rounded),
            label: Text(t.dji_link_flight_view_open),
            onPressed: flowing ? () => unawaited(_relay.openFlightView(djiFlightViewLabels(t))) : null,
          ),
          Text(t.dji_link_flight_view_note, style: context.textTheme.bodySmall),
          if (relay.flightViewFailed || (snapshot?.flightViewFailed ?? false))
            Text(
              t.dji_link_flight_view_failed,
              key: const Key('dji_link_flight_view_failed'),
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
            ),
        ],
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

/// The texts of the flight view's panel, with the placeholders the native side fills four times a second
Map<String, String> djiFlightViewLabels(Translations t) => {
  'live': t.dji_link_flight_view_live,
  'replay': t.dji_link_flight_view_replay(name: '{name}'),
  'noSource': t.dji_link_flight_view_no_source,
  'lost': t.dji_link_flight_view_lost,
  'local': t.dji_link_flight_view_local,
  'noPicture': t.dji_link_flight_view_no_picture,
  'stale': t.dji_link_latency_stale(seconds: '{seconds}'),
  'noValues': t.dji_link_flight_none,
  'flight': t.dji_link_flight_view_flight(
    heading: '{heading}',
    heightMetres: '{heightMetres}',
    speeds: '{speeds}',
    mode: '{mode}',
    motors: '{motors}',
  ),
  'power': t.dji_link_flight_view_power(
    battery: '{battery}',
    volts: '{volts}',
    remote: '{remote}',
    aircraftSignal: '{aircraftSignal}',
    remoteSignal: '{remoteSignal}',
  ),
  'on': t.dji_link_flight_view_on,
  'off': t.dji_link_flight_view_off,
  'valuesStale': t.dji_link_flight_view_values_stale,
  'latency': t.dji_link_flight_view_latency(ms: '{ms}', pictures: '{pictures}'),
  'flyNote': t.dji_link_flight_view_fly_note,
  'observer': t.dji_link_observer_note,
  'watching': t.dji_link_observer_watching,
  'hint': t.dji_link_flight_view_hint,
  'back': t.dji_link_flight_view_back,
};
