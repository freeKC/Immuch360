// What shows before an AV2 video plays on a computer (store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 1.1, 1.3,
// 1.4 and 4), in the place of the player, for a file of the folder library, of "Open with" and of a share: the gate
// lets the player in once each of these is settled, in this order.
//
// 1. A phone, the TV or the Quest: "AV2 videos play in Immuch360 Desktop only for now".
// 2. The setting "AV2 videos (experimental)" off: it says so, with the switch to turn it on there.
// 3. A Mac whose libmpv has neither the y4m demuxer nor the raw video decoder (lot AD4 builds the next one): "AV2
//    videos need a newer Immuch360 Desktop on this Mac".
// 4. The AV2 decoder not installed: the card "Play AV2 videos (experimental)", what it is, its size and its licence,
//    then "Download and play", its progress, Cancel, and why a download failed. Nothing is downloaded before the tap.
//    A version that does not offer it (no size nor sum in its catalogue) says "Not in this version of the app".
// 5. The format read by the probe of the decoder: a stream this version of the decoder does not play gets its name.
// 6. The last speed this computer measured for the format under 0.95 times the frame rate of the video: "This computer
//    decodes this AV2 video at about 7 frames per second and it needs 24: it will pause to catch up", and "Play
//    anyway" (decision D2 of the plan). Without a measure the video plays, and the start rule of the player waits for
//    what it needs.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/ai_immersive/install_sheet.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:logging/logging.dart';

final _log = Logger('Av2Gate');

/// The libmpv releases of macOS whose FFmpeg has neither the yuv4mpegpipe demuxer nor the rawvideo decoder that the
/// pictures of the AV2 decoder need (plan, section 2.4); lot AD4 pins the next one
const macosLibmpvWithoutY4m = {'libmpv-macos-20261020-9'};

/// Whether the libmpv of macOS [release] plays the pictures of the AV2 decoder
bool av2PlaysWithMacLibmpv(String release) => !macosLibmpvWithoutY4m.contains(release);

/// The player of the AV2 [video], [child], once each step at the top of this file is settled
class Av2PlaybackGate extends ConsumerStatefulWidget {
  const Av2PlaybackGate({super.key, required this.video, required this.child});

  final Av2VideoRef video;
  final Widget child;

  @override
  ConsumerState<Av2PlaybackGate> createState() => _Av2PlaybackGateState();
}

class _Av2PlaybackGateState extends ConsumerState<Av2PlaybackGate> {
  late final Future<void> _loaded = _load();
  Future<Av2VideoFormat>? _probe;
  bool _playAnyway = false;

  Future<void> _load() async {
    try {
      await ref.read(av2DecoderProvider).service.load();
    } catch (error, stack) {
      // The decoder then shows as missing, and its download says what is wrong
      _log.warning('the components folder could not be read', error, stack);
    }
  }

  @override
  void didUpdateWidget(Av2PlaybackGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video != widget.video) {
      _probe = null;
      _playAnyway = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    if (!CurrentPlatform.isDesktop) {
      return Av2Notice(key: const Key('av2_notice_not_here'), text: t.av2_error_not_here);
    }
    if (!ref.watch(appConfigProvider.select((config) => config.viewer.av2Videos))) {
      return Av2Notice(
        key: const Key('av2_notice_off'),
        text: t.av2_error_off,
        action: SwitchListTile(
          key: const Key('av2_turn_on'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.av2_settings_title),
          value: false,
          onChanged: (on) => unawaited(ref.read(settingsProvider).write(.viewerAv2Videos, on)),
        ),
      );
    }
    if (CurrentPlatform.isMacOS && !av2PlaysWithMacLibmpv(macosLibmpvRelease)) {
      return Av2Notice(key: const Key('av2_notice_mac'), text: t.av2_error_mac_libmpv);
    }
    final decoder = ref.watch(av2DecoderProvider);
    return FutureBuilder<void>(
      future: _loaded,
      builder: (context, loaded) => loaded.connectionState != ConnectionState.done
          ? const _Waiting()
          : ListenableBuilder(
              listenable: decoder.service,
              builder: (context, _) => decoder.isInstalled ? _probed(context) : Av2InstallCard(decoder: decoder),
            ),
    );
  }

  Widget _probed(BuildContext context) {
    final probe = _probe ??= ref.read(av2ProbeProvider)(widget.video);
    return FutureBuilder<Av2VideoFormat>(
      future: probe,
      builder: (context, snapshot) {
        final t = context.t;
        if (snapshot.hasError) {
          return Av2Notice(
            key: const Key('av2_notice_stopped'),
            text: t.av2_error_decoder_stopped(reason: '${snapshot.error}'),
          );
        }
        final format = snapshot.data;
        if (format == null) {
          return const _Waiting();
        }
        final refused = format.refusedFormat;
        if (refused != null) {
          return Av2Notice(
            key: const Key('av2_notice_format'),
            text: t.av2_error_format(format: refused),
          );
        }
        final speed = ref.watch(av2SpeedProvider)(format);
        if (speed != null && speed.tooSlow && !_playAnyway) {
          return Av2TooSlowNotice(speed: speed, onPlay: () => setState(() => _playAnyway = true));
        }
        return widget.child;
      },
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => const Center(key: Key('av2_waiting'), child: CircularProgressIndicator());
}

/// The frame of the screens of the gate: a card in the middle of the viewer, under the title of the card of the
/// decoder, with [children]
class _Av2Card extends StatelessWidget {
  const _Av2Card({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.memory_rounded, color: context.primaryColor),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.t.av2_install_title, style: context.textTheme.titleMedium)),
                  ],
                ),
                const SizedBox(height: 12),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A sentence in the place of the player, with an [action] under it
class Av2Notice extends StatelessWidget {
  const Av2Notice({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => _Av2Card(children: [Text(text), ?action]);
}

/// "This computer decodes this AV2 video at about 7 frames per second and it needs 24: it will pause to catch up", and
/// Play anyway
class Av2TooSlowNotice extends StatelessWidget {
  const Av2TooSlowNotice({super.key, required this.speed, required this.onPlay});

  final Av2Speed speed;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    return _Av2Card(
      key: const Key('av2_too_slow'),
      children: [
        Text(
          context.t.av2_too_slow(
            fps: av2FpsText(speed.decodedFps, locale),
            needed: av2FpsText(speed.neededFps, locale, exact: true),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton(
            key: const Key('av2_play_anyway'),
            autofocus: true,
            onPressed: onPlay,
            child: Text(context.t.av2_play_anyway),
          ),
        ),
      ],
    );
  }
}

/// The card of a computer without the AV2 decoder: what it is, its size and its licence, "Download and play", its
/// progress and Cancel, and why a download failed; "Not in this version of the app" when this version does not offer
/// it. The gate plays the video once the decoder is installed.
class Av2InstallCard extends StatefulWidget {
  const Av2InstallCard({super.key, required this.decoder});

  final Av2Decoder decoder;

  @override
  State<Av2InstallCard> createState() => _Av2InstallCardState();
}

class _Av2InstallCardState extends State<Av2InstallCard> {
  bool _running = false;
  bool _stopping = false;
  AiDownloadException? _failure;
  Object? _error;

  AiComponentsService get _service => widget.decoder.service;

  Future<void> _download() async {
    final component = widget.decoder.component;
    if (component == null) {
      return;
    }
    setState(() {
      _running = true;
      _stopping = false;
      _failure = null;
      _error = null;
    });
    try {
      // The drive is asked before the first byte, as for the AI components
      final shortage = await _service.spaceShortage([component]);
      if (shortage != null) {
        throw AiDownloadException(AiDownloadFailure.notEnoughSpace, '$shortage', shortage);
      }
      await _service.install(component);
    } on AiDownloadException catch (error) {
      _log.warning('the AV2 decoder was not installed: $error');
      if (mounted) {
        setState(() => _failure = error.failure == AiDownloadFailure.cancelled ? null : error);
      }
    } catch (error, stack) {
      _log.warning('the AV2 decoder was not installed', error, stack);
      if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  void _cancel() {
    final component = widget.decoder.component;
    if (component != null) {
      setState(() => _stopping = true);
      _service.cancel(component);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final decoder = widget.decoder;
    final component = decoder.component;
    if (component == null || !decoder.offered) {
      return _Av2Card(
        key: const Key('av2_install_card'),
        children: [Text(t.ai_immersive_unavailable_build, key: const Key('av2_install_unavailable'))],
      );
    }
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final status = decoder.status;
        final total = status.total;
        final fraction = total == null || total == 0 ? null : (status.received / total).clamp(0.0, 1.0);
        final downloading = _running || status.state == AiComponentState.downloading;
        final failure = _failure;
        final error = _error;
        return _Av2Card(
          key: const Key('av2_install_card'),
          children: [
            Text(t.av2_install_body(size: formatBytes(decoder.downloadBytes))),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AiLicenceLink(component: component),
            ),
            if (downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: fraction),
              const SizedBox(height: 4),
              Text(
                t.av2_install_progress(percent: ((fraction ?? 0) * 100).floor()),
                key: const Key('av2_install_progress'),
              ),
            ],
            if (failure != null || error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  failure != null ? aiDownloadFailureText(t, failure) : t.av2_install_failed(reason: '$error'),
                  key: const Key('av2_install_failure'),
                  style: TextStyle(color: context.colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: downloading
                  ? TextButton(
                      key: const Key('av2_install_cancel'),
                      onPressed: _stopping ? null : _cancel,
                      child: Text(t.cancel),
                    )
                  : FilledButton(
                      key: const Key('av2_install_button'),
                      autofocus: true,
                      onPressed: () => unawaited(_download()),
                      child: Text(t.av2_install_button),
                    ),
            ),
          ],
        );
      },
    );
  }
}
