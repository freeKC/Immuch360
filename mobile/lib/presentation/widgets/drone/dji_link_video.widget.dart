// The video panel of the DJI link page: the live picture of the drone's camera, decoded on this device from the cable
// (or from a capture being played), with the counters of the path from the cable to the screen.
//
// The picture is a platform view (DjiLinkVideoView.kt) holding a SurfaceView the decoder renders straight into, the
// pattern of the camera live view. The native side gives the picture to the most recently created view that still has
// a surface, so the full screen route and the panel never restart the decoder. Receive only: nothing here sends a byte.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';

/// The type of the platform view, DjiLinkVideoViewFactory.VIEW_TYPE in Kotlin
const djiLinkVideoViewType = 'immuch/dji_link_video';

/// Builds the picture; null builds the platform view. Tests put a placeholder in its place.
final djiLinkVideoViewBuilderProvider = Provider<Widget Function()?>((_) => null);

/// The picture itself: the platform view on Android, black elsewhere. It never takes the focus nor a touch.
class DjiLinkVideoSurface extends ConsumerWidget {
  const DjiLinkVideoSurface({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final builder = ref.watch(djiLinkVideoViewBuilderProvider);
    final Widget view;
    if (builder != null) {
      view = builder();
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      view = PlatformViewLink(
        viewType: djiLinkVideoViewType,
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        ),
        onCreatePlatformView: (params) {
          final controller = PlatformViewsService.initSurfaceAndroidView(
            id: params.id,
            viewType: djiLinkVideoViewType,
            layoutDirection: TextDirection.ltr,
          )..addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
          unawaited(controller.create());
          return controller;
        },
      );
    } else {
      view = const ColoredBox(color: Colors.black);
    }
    return ExcludeFocus(child: IgnorePointer(child: view));
  }
}

/// The short line drawn over the picture: pictures per second, Mbit/s and the median decode time
String djiLinkVideoOverlay(Translations t, DjiLinkDecode decode) {
  final rate = t.dji_link_video_rate(
    pictures: decode.picturesPerSecond.toStringAsFixed(0),
    megabits: decode.megabitsPerSecond.toStringAsFixed(1),
  );
  final median = decode.decodeMedianMs;
  return median == null ? rate : '$rate, ${median.toStringAsFixed(1)} ms';
}

/// Whether pictures come out of the decoder: the platform view is built only then. A surface with no picture in it is
/// transparent, and under hybrid composition it shows whatever was drawn there before instead of black; while it is not
/// built, the decoder renders into its parking surface and moves to the view as soon as the view exists.
bool djiLinkPictureFlows(DjiLinkDecode? decode) {
  final ago = decode?.lastOutputAgoMs;
  return decode != null && decode.decoderName != null && ago != null && ago < djiLinkPictureTimeoutMs;
}

/// After this long without a picture out of the decoder, the panel draws black instead of the platform view
const djiLinkPictureTimeoutMs = 3000;

/// The aspect ratio of the stream, 16:9 until a description gave its size
double djiLinkVideoAspect(DjiLinkDecode? decode) {
  final width = decode?.width;
  final height = decode?.height;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return 16 / 9;
  }
  return width / height;
}

class DjiLinkVideoPanel extends ConsumerWidget {
  const DjiLinkVideoPanel({super.key, required this.decode, this.showCounters = true});

  final DjiLinkDecode? decode;

  /// The counters and the decoder choice under the picture
  final bool showCounters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final decode = this.decode;
    final overlay = context.textTheme.labelSmall?.copyWith(color: Colors.white, fontFamily: 'monospace');
    return Column(
      key: const Key('dji_link_video_panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: djiLinkVideoAspect(decode),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (djiLinkPictureFlows(decode)) const DjiLinkVideoSurface(),
              if (decode != null)
                Positioned(
                  left: 6,
                  bottom: 4,
                  right: 48,
                  child: Text(djiLinkVideoOverlay(t, decode), key: const Key('dji_link_video_overlay'), style: overlay),
                ),
              Positioned(
                right: 0,
                top: 0,
                child: IconButton(
                  key: const Key('dji_link_video_full_screen'),
                  tooltip: t.dji_link_video_full_screen,
                  color: Colors.white,
                  icon: const Icon(Icons.fullscreen_rounded),
                  onPressed: () => unawaited(openDjiLinkFullScreen(context)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          decode == null ? t.dji_link_video_waiting : djiLinkVideoStateText(t, decode),
          key: const Key('dji_link_video_state'),
          style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            t.dji_link_video_private,
            key: const Key('dji_link_video_private'),
            style: context.textTheme.bodySmall,
          ),
        ),
        if (decode != null && showCounters) ...[const SizedBox(height: 6), _DjiLinkVideoCounters(decode: decode)],
      ],
    );
  }
}

class _DjiLinkVideoCounters extends ConsumerWidget {
  const _DjiLinkVideoCounters({required this.decode});

  final DjiLinkDecode decode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final codec = switch (decode.codec) {
      'h265' => 'H.265',
      'h264' => 'H.264',
      _ => '-',
    };
    final dimensions = decode.width == null ? '-' : '${decode.width} x ${decode.height}';
    final level = [
      ?decode.profileName,
      if (decode.highTier != null) decode.highTier! ? 'High tier' : 'Main tier',
      if (decode.levelName != null) 'level ${decode.levelName}',
    ].join(' ');
    final decoderName = decode.decoderName;
    final decoder = decoderName == null
        ? t.dji_link_video_decoder_none
        : decode.decoderHardware == true
        ? t.dji_link_video_decoder_hardware(name: decoderName)
        : t.dji_link_video_decoder_software(name: decoderName);
    final switchReason = djiLinkSwitchReasonText(t, decode.switchReason);
    final keyAgo = decode.keyPictureAgoMs;
    return Column(
      key: const Key('dji_link_video_counters'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DjiLinkFact(
          t.dji_link_video_codec,
          t.dji_link_video_codec_value(codec: codec, dimensions: dimensions, level: level.isEmpty ? '-' : level),
        ),
        DjiLinkFact(t.dji_link_video_description, djiLinkDescriptionSourceText(t, decode.descriptionSource)),
        DjiLinkFact(t.dji_link_video_decoder, decoder),
        DjiLinkFact(t.dji_link_video_low_latency, decode.lowLatency ? t.dji_link_yes : t.dji_link_no),
        DjiLinkFact(t.dji_link_video_switches, '${decode.switches}'),
        if (switchReason != null)
          Text(switchReason, key: const Key('dji_link_video_switch_reason'), style: context.textTheme.bodySmall),
        DjiLinkFact(
          t.dji_link_video_pictures,
          t.dji_link_video_pictures_value(
            arrived: '${decode.unitsIn}',
            decoded: '${decode.decoded}',
            shown: '${decode.shown}',
            skipped: '${decode.droppedAtDisplay}',
          ),
        ),
        DjiLinkFact(t.dji_link_video_overruns, '${decode.overruns}'),
        DjiLinkFact(t.dji_link_video_too_large, '${decode.tooLarge}'),
        DjiLinkFact(t.dji_link_video_errors, '${decode.errors}'),
        DjiLinkFact(t.dji_link_video_without_description, '${decode.unitsWithoutDescription}'),
        DjiLinkFact(
          t.dji_link_video_rate_label,
          t.dji_link_video_rate(
            pictures: decode.picturesPerSecond.toStringAsFixed(1),
            megabits: decode.megabitsPerSecond.toStringAsFixed(2),
          ),
        ),
        DjiLinkFact(
          t.dji_link_video_decode_time,
          t.dji_link_video_decode_time_value(
            last: djiLinkNumber(decode.decodeLastMs),
            median: djiLinkNumber(decode.decodeMedianMs),
            high: djiLinkNumber(decode.decodeP95Ms),
          ),
        ),
        DjiLinkFact(
          t.dji_link_video_in_process,
          t.dji_link_video_in_process_value(
            median: djiLinkNumber(decode.inProcessMedianMs, 2),
            high: djiLinkNumber(decode.inProcessP95Ms, 2),
          ),
        ),
        DjiLinkFact(
          t.dji_link_video_first_picture,
          decode.firstPictureMs == null ? t.dji_link_never : '${decode.firstPictureMs} ms',
        ),
        DjiLinkFact(t.dji_link_video_lost, '${decode.lostPictures}'),
        DjiLinkFact(t.dji_link_video_restarts, '${decode.encoderRestarts}'),
        DjiLinkFact(
          t.dji_link_video_key_picture,
          keyAgo == null
              ? t.dji_link_video_key_picture_none
              : t.dji_link_video_key_picture_ago(seconds: (keyAgo / 1000).toStringAsFixed(1)),
        ),
        const SizedBox(height: 6),
        Text(t.dji_link_video_choice, style: context.textTheme.labelMedium),
        Wrap(
          spacing: 8,
          children: [
            for (final choice in DjiLinkDecoderChoice.values)
              ChoiceChip(
                key: Key('dji_link_video_choice_${choice.name}'),
                label: Text(switch (choice) {
                  DjiLinkDecoderChoice.automatic => t.dji_link_video_choice_automatic,
                  DjiLinkDecoderChoice.hardware => t.dji_link_video_choice_hardware,
                  DjiLinkDecoderChoice.software => t.dji_link_video_choice_software,
                }),
                selected: decode.choice == choice,
                onSelected: (_) => unawaited(ref.read(djiLinkProvider.notifier).setDecoderChoice(choice)),
              ),
          ],
        ),
      ],
    );
  }
}

/// The picture alone on a black screen, pushed on the root navigator; Back leaves
Future<void> openDjiLinkFullScreen(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const DjiLinkFullScreenVideo()));

class DjiLinkFullScreenVideo extends ConsumerWidget {
  const DjiLinkFullScreenVideo({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decode = ref.watch(djiLinkProvider.select((state) => state.snapshot?.videoDecode));
    final t = context.t;
    return Scaffold(
      key: const Key('dji_link_video_full_screen_route'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: djiLinkVideoAspect(decode),
                child: djiLinkPictureFlows(decode) ? const DjiLinkVideoSurface() : const SizedBox.expand(),
              ),
            ),
            if (decode != null)
              Positioned(
                left: 12,
                bottom: 8,
                child: Text(
                  djiLinkVideoOverlay(t, decode),
                  style: context.textTheme.labelSmall?.copyWith(color: Colors.white, fontFamily: 'monospace'),
                ),
              ),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                key: const Key('dji_link_video_leave_full_screen'),
                tooltip: t.dji_link_video_leave_full_screen,
                color: Colors.white,
                icon: const Icon(Icons.fullscreen_exit_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
