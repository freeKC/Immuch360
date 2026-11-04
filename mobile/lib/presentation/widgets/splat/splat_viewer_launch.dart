// Opening a splat in the splat viewer of the computers, phones and tablets (plan of 2 November 2026): a tap on a splat
// opens the scene at once when this device shows it, its page otherwise (the reason it is refused). A splat above the
// cap of the device is made ready first, with its progress and a Cancel; the page gets its texts in the app's language
// and the app's colours; how the viewing ended is said when it was not the user's Back. On a computer (lot SVC) the
// cap follows the chip that draws and the memory, the page watches the first frames of a splat shown whole, and the
// reduced copy it offers opens as soon as the user takes it.

import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_save_launch.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/device_features.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/network_splat.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';

final _log = Logger('SplatViewerLaunch');

/// Spark's cut of each gaussian: sqrt(5) on phones and tablets (measured 38 to 60 % faster), its own sqrt(8) on
/// computers
const splatPhoneMaxStdDev = 2.2360679774997896;
const splatComputerMaxStdDev = 2.8284271247461903;

/// The most pixels drawn per CSS pixel: 1 on phones and tablets until a real phone was measured; 2 on computers (a
/// panel at 200 % was drawn at a quarter of its pixels, the RTX 4060 at 120 frames per second), the page's quality
/// steps going down to half a pixel when frames are slow
const splatPhonePixelRatioMax = 1.0;
const splatComputerPixelRatioMax = 2.0;

/// The texts of the page, in the app's language: the templates keep their {names} for the page to fill
Map<String, String> splatViewerPageTexts(
  Translations t, {
  required String countLine,
  String? reducedLine,
  String? wholeLine,
}) => {
  'back': t.back,
  'reset': t.reset,
  'upright': t.splat_upright,
  'modeWalk': t.splat_mode_walk,
  'modeOrbit': t.splat_mode_orbit,
  'gyroscope': t.panorama_gyroscope,
  'noGyroscope': t.panorama_no_gyroscope,
  'info': t.info,
  'helpLabel': t.splat_controls,
  'loading': t.splat_loading,
  'countLine': countLine,
  'reducedLine': ?reducedLine,
  'wholeLine': ?wholeLine,
  'slowLine': t.splat_slow_line(fps: '{fps}'),
  'slowReduce': t.splat_slow_reduce(kept: '{kept}', total: '{total}'),
  'slowKeep': t.splat_slow_keep,
  'hintKeys': t.splat_hint_keys(keys: '{keys}', updown: '{updown}'),
  'hintKeysOrbit': t.splat_hint_keys_orbit(keys: '{keys}'),
  'hintTouch': t.splat_hint_touch,
  'hintTouchOrbit': t.splat_hint_touch_orbit,
  'keysFallback': t.splat_keys_any_layout,
  'upDownFallback': t.splat_updown_any_layout,
  'focusHint': t.splat_focus_hint,
  'kindPlace': t.splat_kind_place,
  'kindObject': t.splat_kind_object(size: '{size}'),
  'fpsLine': t.splat_fps_line(fps: '{fps}'),
  'gpuLine': t.splat_gpu_line(name: '{name}'),
  'turnedLine': t.splat_turned(axis: '{axis}'),
  'axisYUp': t.splat_axis_y_up,
  'axisZUp': t.splat_axis_z_up,
  'axisYDown': t.splat_axis_y_down,
  'heavy': t.splat_heavy,
  'needsWebgl2': t.splat_needs_webgl2,
  'needsSimd': CurrentPlatform.isAndroid ? t.splat_update_webview : t.splat_needs_simd,
  'graphicsLost': t.splat_graphics_lost,
  'failed': t.splat_failed(reason: '{reason}'),
};

/// The colour [color] as the page takes it: "#rrggbb"
String splatCssColor(Color color) {
  String hex(double channel) => (channel * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${hex(color.r)}${hex(color.g)}${hex(color.b)}';
}

/// What to say once a viewing ended as [outcome], null when nothing is to be said
String? splatViewerEndText(Translations t, SplatViewerOutcome outcome) => switch (outcome.end) {
  // On Linux a window that stayed blank: WebKitGTK's DMABUF renderer and some NVIDIA drivers (plan section 2.5); the
  // app names the variable and never sets it by itself
  SplatViewerEnd.closed when outcome.noPicture && CurrentPlatform.isLinux => t.splat_linux_no_picture,
  SplatViewerEnd.closed || SplatViewerEnd.cancelled || SplatViewerEnd.reduce => null,
  SplatViewerEnd.rendererGone => t.splat_renderer_gone,
  SplatViewerEnd.stalled => t.splat_graphics_lost,
  SplatViewerEnd.noWebView =>
    CurrentPlatform.isWindows ? t.splat_needs_webview2 : (CurrentPlatform.isAndroid ? t.splat_update_webview : null),
  SplatViewerEnd.unsupported =>
    outcome.unsupported == 'webgl2'
        ? t.splat_needs_webgl2
        : (CurrentPlatform.isAndroid ? t.splat_update_webview : t.splat_needs_simd),
  SplatViewerEnd.noSpace => t.splat_no_space_device,
  SplatViewerEnd.failed => t.splat_open_file_failed,
};

SplatGateVerdict? _verdict(
  SplatDeviceClass? device,
  bool large,
  SplatProbe probe,
  String name,
  int fileBytes, {
  SplatComputer? computer,
  SplatFrameAnswer? answer,
}) {
  if (device != SplatDeviceClass.phone && device != SplatDeviceClass.computer) {
    return null;
  }
  return splatViewerGateOf(
    probe: probe,
    name: name,
    fileBytes: fileBytes,
    largeSplats: large,
    device: device!,
    computer: computer ?? const SplatComputer(),
    answer: answer,
  );
}

/// The answer kept for the file [name] of [fileBytes] on a computer, null elsewhere or when none
Future<SplatFrameAnswer?> _answerOf(WidgetRef ref, SplatDeviceClass? device, String name, int? fileBytes) async {
  if (device != SplatDeviceClass.computer || fileBytes == null) {
    return null;
  }
  try {
    return await ref.read(splatAnswerStoreProvider).answer(name, fileBytes);
  } catch (error) {
    _log.fine('No answer read for $name: $error');
    return null;
  }
}

/// The gate of the splat viewer of this computer, phone or tablet for the splat whose head said [probe], the file
/// [name] of [fileBytes], read now (the chip and the memory of a computer, its answer for the file); null on another
/// device. A splat photo asks it again with the head of its scene, which wins over its packet.
Future<SplatGateVerdict?> splatViewerVerdictNow(
  WidgetRef ref,
  SplatProbe probe, {
  required String name,
  required int fileBytes,
}) async {
  final device = ref.read(splatDeviceClassProvider);
  final computer = await ref.read(splatComputerNowProvider)();
  final answer = await _answerOf(ref, device, name, fileBytes);
  return _verdict(
    device,
    ref.read(appConfigProvider).viewer.largeSplats,
    probe,
    name,
    fileBytes,
    computer: computer,
    answer: answer,
  );
}

/// Opens the splat file of [key]: in the splat viewer at once when this device shows it, on its page otherwise
Future<void> openSplatFile(BuildContext context, WidgetRef ref, SplatFileKey key) async {
  if (ref.read(splatFlatViewerProvider) && ref.read(splatViewerServiceProvider) != null) {
    try {
      final probe = await ref.read(splatProbeProvider(key).future);
      final size = key.size ?? (key.sourceId == null ? File(key.path).lengthSync() : null);
      final name = key.path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ?? key.path;
      final device = ref.read(splatDeviceClassProvider);
      final computer = await ref.read(splatComputerNowProvider)();
      final answer = await _answerOf(ref, device, name, size);
      final verdict = _verdict(
        device,
        ref.read(appConfigProvider).viewer.largeSplats,
        probe,
        name,
        size ?? 1,
        computer: computer,
        answer: answer,
      );
      if (verdict != null && verdict.isOpen && probe is SplatHead && context.mounted) {
        final source = key.sourceId == null
            ? SplatViewerSource.local(key.path)
            : SplatViewerSource.share(key.sourceId!, key.path);
        final cap = verdict.request!.maxGaussians;
        await showSplatViewer(
          context,
          ref,
          source: source,
          head: probe,
          fileBytes: size ?? 0,
          cap: cap,
          watchFrames: device != null && splatWatchesFrames(device: device, head: probe, cap: cap, answer: answer),
        );
        return;
      }
    } catch (error) {
      _log.warning('Could not read the splat ${key.path}: $error');
    }
  }
  if (context.mounted) {
    await context.pushRoute(SplatRoute(sourceId: key.sourceId, path: key.path, size: key.size));
  }
}

/// Shows [source] (its head [head], [fileBytes] long) with at most [cap] gaussians in the splat viewer: a dialog with
/// the progress and Cancel while a splat above the cap is made ready, then the viewer; what went wrong is said after.
/// With [watchFrames] the page watches its first frames; the reduced copy the user takes there opens right after.
Future<void> showSplatViewer(
  BuildContext context,
  WidgetRef ref, {
  required SplatViewerSource source,
  required SplatHead head,
  required int fileBytes,
  required int cap,
  bool watchFrames = false,
}) async {
  final service = ref.read(splatViewerServiceProvider);
  if (service == null) {
    return;
  }
  final t = context.t;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final locale = Localizations.localeOf(context).toLanguageTag();
  final theme = Theme.of(context);
  final device = ref.read(splatDeviceClassProvider);
  final phone = device == SplatDeviceClass.phone;
  final reduced = head.gaussians > cap;
  final look = SplatViewerLook(
    texts: splatViewerPageTexts(
      t,
      countLine: t.splat_count(count: splatCountText(reduced ? cap : head.gaussians, locale)),
      reducedLine: reduced
          ? t.splat_reduced(kept: splatCountText(cap, locale), total: splatCountText(head.gaussians, locale))
          : null,
      wholeLine: reduced ? null : t.splat_shown_whole(count: splatCountText(head.gaussians, locale)),
    ),
    locale: locale,
    dark: theme.brightness == Brightness.dark,
    primary: splatCssColor(theme.colorScheme.primary),
    device: phone ? 'phone' : 'computer',
    gyroscope: phone && ref.read(deviceFeaturesProvider).gyroscope,
    maxStdDev: phone ? splatPhoneMaxStdDev : splatComputerMaxStdDev,
    pixelRatioMax: phone ? splatPhonePixelRatioMax : splatComputerPixelRatioMax,
  );
  // Save to Immich in the page; the scene of a splat photo is on the server already
  final onServer =
      source.sourceId == null && source.path.split(RegExp(r'[/\\]')).last.startsWith(SplatViewerCache.serverPrefix);
  final saving = splatViewerSavingFor(
    context,
    ref,
    source: source,
    head: head,
    fileBytes: fileBytes,
    onServer: onServer,
  );
  final progress = ValueNotifier<(SplatPrepareStep, double)?>(null);
  final cancel = SplatPrepareCancel();
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogShown = false;
  void closeDialog() {
    if (dialogShown) {
      dialogShown = false;
      navigator.pop();
    }
  }

  if (reduced) {
    dialogShown = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (context) => SplatPrepareDialog(progress: progress, onCancel: cancel.cancel),
      ).whenComplete(() {
        // Gone without closeDialog: the routes changed under it (a splat dropped on the window, or given by a later
        // start, replaces them). The preparation stops as on Back, or the viewer would open over the other page
        if (dialogShown) {
          dialogShown = false;
          cancel.cancel();
        }
      }),
    );
  }
  final SplatViewerOutcome outcome;
  try {
    outcome = await service.show(
      source: source,
      head: head,
      fileBytes: fileBytes,
      cap: cap,
      look: look,
      progress: (step, done) => progress.value = (step, done),
      cancel: cancel,
      onOpening: closeDialog,
      watchFrames: watchFrames,
      saving: saving,
    );
  } finally {
    saving?.viewerClosed();
    closeDialog();
    progress.dispose();
  }
  // The reduced copy the page offered: made now (or found kept), then shown
  final keep = outcome.keep;
  if (outcome.end == SplatViewerEnd.reduce && keep != null && keep < head.gaussians && context.mounted) {
    await showSplatViewer(context, ref, source: source, head: head, fileBytes: fileBytes, cap: keep);
    return;
  }
  final text = splatViewerEndText(t, outcome);
  if (text != null) {
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }
}

String _percent(BuildContext context, double share) {
  final locale = Localizations.localeOf(context).toLanguageTag();
  try {
    return NumberFormat.percentPattern(locale).format(share);
  } on ArgumentError {
    return NumberFormat.percentPattern('en').format(share);
  }
}

/// The progress of the preparation of a splat, with Cancel: the download of the scene of a splat photo of
/// [downloadTotal] bytes ("Downloading the splat scene: 1.2 MiB of 3.9 MiB"), the copy from a share, the reduction
class SplatPrepareDialog extends StatelessWidget {
  const SplatPrepareDialog({super.key, required this.progress, required this.onCancel, this.downloadTotal});

  final ValueNotifier<(SplatPrepareStep, double)?> progress;
  final VoidCallback onCancel;
  final int? downloadTotal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The system Back is Cancel: popping the dialog alone would leave the copy and the reduction running, and the
    // viewer would open later over whatever page the user went to
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          onCancel();
        }
      },
      child: AlertDialog(
        content: ValueListenableBuilder<(SplatPrepareStep, double)?>(
          valueListenable: progress,
          builder: (context, value, _) {
            final percent = _percent(context, value?.$2 ?? 0);
            final total = downloadTotal;
            final line = switch (value?.$1) {
              SplatPrepareStep.download when total != null => t.splat_photo_downloading(
                done: formatBytes((total * (value?.$2 ?? 0)).round()),
                total: formatBytes(total),
              ),
              SplatPrepareStep.copy => t.splat_copying_progress(percent: percent),
              _ => t.splat_preparing_progress(percent: percent),
            };
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(value == null ? t.splat_preparing : line, key: const Key('splat_prepare_line')),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: value?.$2),
              ],
            );
          },
        ),
        actions: [TextButton(key: const Key('splat_prepare_cancel'), onPressed: onCancel, child: Text(t.cancel))],
      ),
    );
  }
}
