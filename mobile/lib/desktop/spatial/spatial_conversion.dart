// Spatial 2.5D of a plain photo on the computers (release 53, FreeKC 26 November 2026): an ordinary 2D photo of the
// library viewer or of the page of a share gets "Spatial 2.5D" too, while the switch of the settings is on and this
// computer offers the 3D photo of "Make 3D (AI)" for it (the same rules: the AI features on, a flat photo by
// aiSourceProvider or shareConversionKinds, a gate that does not refuse; missing components do not hide it, the dialog
// installs them). Pressed, it opens the 2.5D page at once on a 3D photo made by AI from it when one is known (the
// versions of the details of the viewer, those of the folder of a share). Otherwise it opens the conversion dialog on
// the 3D photo alone (kindOnly): its components, relief strength, destination, network folder question and "If a
// version exists" as for "Make 3D (AI)", and Convert hands the job to the queue of the conversions, as that entry
// does. A small dialog then follows the job (its state, its bar, Cancel; Escape cancels too); once the job is done,
// the 2.5D page opens on the file it wrote, the relief said estimated by AI. A job skipped for a version with the same
// settings opens that version. A failure shows the words of the panel of the conversions, with Close.
//
// A 360° photo of one eye of the whole sphere gets it the same way, through the 3D version of a 360° photo of "Make
// 3D (AI)" (stereo_panorama_engine.dart, `<name>_360_3D.jpg`, two eyes one above the other): offered while this build
// makes that type (offeredConversionKindsProvider) and its gate does not refuse, on the photos that type takes
// (aiSourceProvider, shareConversionKinds); its 3D version made by AI known for it opens at once, else the dialog on
// that type alone, then the 2.5D page of a 3D sphere (spatial_sphere_render.dart) on the file written.
//
// Nothing here on phones, TVs or a Quest: the pages ask only on a computer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/library/versions.provider.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/ai_immersive/share_versions.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SpatialConversion');

/// The layout of a 3D photo the app made: two eyes of full width side by side, the left one first
/// (`_3D_LRF_Full_SBS`)
const spatialMadePhotoLayout = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);

/// The layout of the 3D version of a 360° photo the app makes (stereo_panorama_engine.dart): the whole sphere, the left
/// eye on top (`_360_3D`)
const spatialMadeSphereLayout = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, sphere: fullSphereCrop);

/// The layout of the 3D photo or 3D sphere a job of [kind] makes
SpatialPhotoLayout spatialMadeLayoutOf(ConversionKind kind) =>
    kind == ConversionKind.stereoPanoramaFromPanorama ? spatialMadeSphereLayout : spatialMadePhotoLayout;

/// The largest side a 3D photo of ours is decoded at for the 2.5D page, as the page of a share decodes its photos
const spatialMadePhotoMaxSide = 4096;

/// A 3D photo made by AI the 2.5D page opens: its picture, the name of its file, how its eyes are packed
typedef SpatialMadePhoto = ({ImageProvider image, String name, SpatialPhotoLayout layout});

/// [image] decoded at most [spatialMadePhotoMaxSide] pixels on its long side: two eyes of an 8K photo would not fit
ImageProvider spatialCappedImage(ImageProvider image) =>
    ResizeImage(image, width: spatialMadePhotoMaxSide, height: spatialMadePhotoMaxSide, policy: ResizeImagePolicy.fit);

/// Whether this computer runs the 3D photo now, as "Make 3D (AI)" tells it: a gate that answered and does not refuse
/// (the system, the processor, the memory, a group held back by this version); components to install do not refuse
bool _photoGateOpen(WidgetRef ref, {AiFeature feature = AiFeature.stereoPhoto}) {
  final gate = ref.watch(aiGateResultForProvider(feature)).valueOrNull;
  return gate != null && !aiGateRefuses(gate);
}

/// Whether this build makes the 3D version of a 360° photo now: its engine registered and its group not held back
/// (offeredConversionKindsProvider), its gate open as for the 3D photo
bool _sphereKindOpen(WidgetRef ref) =>
    ref.watch(offeredConversionKindsProvider).contains(ConversionKind.stereoPanoramaFromPanorama) &&
    _photoGateOpen(ref, feature: AiFeature.stereoPanorama);

bool _spatialEnabled(WidgetRef ref) => ref.watch(appConfigProvider.select((config) => config.viewer.spatial25d));

/// Whether the viewer of the library offers "Spatial 2.5D" on [asset] through a 3D photo made first: a photo "Make 3D
/// (AI)" takes for a 3D photo (aiSourceProvider), the AI features and the Spatial 2.5D switch on, a gate that does not
/// refuse. The caller asks only for a photo the 2.5D page does not take as it is.
bool spatialConversionOffered(WidgetRef ref, BaseAsset asset) =>
    asset.isImage &&
    ref.watch(aiFeaturesEnabledProvider) &&
    ref.watch(aiSourceProvider((asset: asset, kind: ConversionKind.sbsFromPhoto))) &&
    _photoGateOpen(ref) &&
    _spatialEnabled(ref);

/// The same for the photo of a share at [entry] once its page read its file ([info]; nothing before), of [width] x
/// [height] pixels when known: the rule of "Make 3D (AI)" on a share (shareConversionKinds)
bool spatialConversionOfferedForShare(
  WidgetRef ref,
  NetworkEntry entry,
  NetworkMediaInfo? info, {
  int? width,
  int? height,
}) =>
    info != null &&
    entry.isImage &&
    ref.watch(aiFeaturesEnabledProvider) &&
    shareConversionKinds(entry, info, const [ConversionKind.sbsFromPhoto], width: width, height: height).isNotEmpty &&
    _photoGateOpen(ref) &&
    // Read last: the page of a photo "Make 3D (AI)" does not take never depends on the switch
    _spatialEnabled(ref);

/// The same for a 360° photo of one eye through its 3D version (see the top of this file): a photo "Make 3D (AI)" takes
/// for that type (aiSourceProvider), this build making it now, the AI features and the Spatial 2.5D switch on
bool spatialSphereConversionOffered(WidgetRef ref, BaseAsset asset) =>
    asset.isImage &&
    ref.watch(aiFeaturesEnabledProvider) &&
    ref.watch(aiSourceProvider((asset: asset, kind: ConversionKind.stereoPanoramaFromPanorama))) &&
    _sphereKindOpen(ref) &&
    _spatialEnabled(ref);

/// What "Spatial 2.5D" makes first for the library photo [asset] that the 2.5D page does not take as it is: the 3D
/// photo of a flat photo, the 3D version of a 360° photo, or nothing
ConversionKind? spatialConversionKindOf(WidgetRef ref, BaseAsset asset) {
  if (spatialConversionOffered(ref, asset)) {
    return ConversionKind.sbsFromPhoto;
  }
  return spatialSphereConversionOffered(ref, asset) ? ConversionKind.stereoPanoramaFromPanorama : null;
}

/// The same for the photo of a share at [entry] once its page read its file ([info]), of [width] x [height] pixels
/// when known (shareConversionKinds)
ConversionKind? spatialConversionKindOfShare(
  WidgetRef ref,
  NetworkEntry entry,
  NetworkMediaInfo? info, {
  int? width,
  int? height,
}) {
  if (spatialConversionOfferedForShare(ref, entry, info, width: width, height: height)) {
    return ConversionKind.sbsFromPhoto;
  }
  final sphere =
      info != null &&
      entry.isImage &&
      ref.watch(aiFeaturesEnabledProvider) &&
      shareConversionKinds(
        entry,
        info,
        const [ConversionKind.stereoPanoramaFromPanorama],
        width: width,
        height: height,
      ).isNotEmpty &&
      _sphereKindOpen(ref) &&
      _spatialEnabled(ref);
  return sphere ? ConversionKind.stereoPanoramaFromPanorama : null;
}

/// The 3D photo made by AI among the versions the details of the viewer list for a library photo: the first one that
/// can be opened now; null when there is none
VersionFile? madeStereoVersionOf(PhotoVersions versions) => versions.versions
    .where((version) => version.kind == ImmersiveKind.stereoPhoto && version.isEstimatedRelief && version.available)
    .firstOrNull;

/// The 3D photo made by AI among the versions of a photo of a share in its folder (newest first, findShareVersions),
/// one of a format this version reads; null when there is none
ShareVersion? madeShareStereoVersionOf(Iterable<ShareVersion> versions) => versions
    .where(
      (version) =>
          version.kind == ImmersiveKind.stereoPhoto &&
          (version.photo?.isEstimatedRelief ?? false) &&
          (version.photo?.canShowIn3d ?? false),
    )
    .firstOrNull;

/// The 3D version made by AI of a 360° photo among the versions the details of the viewer list for it: the first one
/// that can be opened now; null when there is none
VersionFile? madeSphereVersionOf(PhotoVersions versions) => versions.versions
    .where((version) => version.kind == ImmersiveKind.stereoPanorama360 && version.available)
    .firstOrNull;

/// The 3D version made by AI of a 360° photo of a share among the versions in its folder (newest first,
/// findShareVersions, which keeps only those of two eyes one above the other); null when there is none
ShareVersion? madeShareSphereVersionOf(Iterable<ShareVersion> versions) =>
    versions.where((version) => version.kind == ImmersiveKind.stereoPanorama360).firstOrNull;

/// Opens the conversion dialog on the 3D photo alone (or on the type [kind] alone) for the photo of [assets] or of
/// [shareFiles], and gives the id of its job once Convert handed it to the queue; null when the dialog closed without it
Future<String?> launchSpatialConversion(
  BuildContext context, {
  List<BaseAsset> assets = const [],
  List<NetworkEntry> shareFiles = const [],
  ConversionKind kind = ConversionKind.sbsFromPhoto,
}) async {
  String? queued;
  await showDialog<bool>(
    context: context,
    builder: (context) => ConversionDialog(
      assets: assets,
      shareFiles: shareFiles,
      kind: kind,
      kindOnly: true,
      onQueued: (ids) => queued = ids.firstOrNull,
    ),
  );
  return queued;
}

typedef SpatialConversionLauncher =
    Future<String?> Function(BuildContext context, {List<BaseAsset> assets, List<NetworkEntry> shareFiles});

/// See [launchSpatialConversion]; replaced in the tests
final spatialConversionLauncherProvider = Provider<SpatialConversionLauncher>((ref) => launchSpatialConversion);

/// The same on the 3D version of a 360° photo alone; replaced in the tests
final spatialSphereConversionLauncherProvider = Provider<SpatialConversionLauncher>(
  (ref) =>
      (context, {assets = const [], shareFiles = const []}) => launchSpatialConversion(
        context,
        assets: assets,
        shareFiles: shareFiles,
        kind: ConversionKind.stereoPanoramaFromPanorama,
      ),
);

/// The 3D photo (or 3D sphere, by the kind of the job) [job] ended with: the file it wrote, read at once (that of a
/// photo of a share leaves this computer once it is on the share), or the version with the same settings it was
/// skipped for, opened by [existing]; null for any other end
Future<SpatialMadePhoto?> spatialJobPhoto(
  ConversionJob job, {
  required Future<ImageProvider?> Function(String path) existing,
}) async {
  final String? path;
  final ImageProvider? image;
  if (job.state == ConversionState.done) {
    path = job.writtenPath;
    image = path == null ? null : spatialCappedImage(MemoryImage(await File(path).readAsBytes()));
  } else if (job.state == ConversionState.skipped && job.existingVersionPath != null) {
    path = job.existingVersionPath;
    image = await existing(path!);
  } else {
    return null;
  }
  return image == null ? null : (image: image, name: p.basename(path!), layout: spatialMadeLayoutOf(job.kind));
}

/// The 3D photo made by AI already known for the photo pressed, null when there is none; past this time it is taken
/// for none, so that a lookup that hangs never holds the button
const _lookupWait = Duration(seconds: 10);

/// What "Spatial 2.5D" does on a plain photo named [name] (see the top of this file): [known] looks for a 3D photo
/// made by AI from it, [launch] opens the conversion dialog and gives the id of the job queued, [existing] opens a
/// version with the same settings that the job was skipped for, [open] opens the 2.5D page
Future<void> runSpatialConversion(
  BuildContext context, {
  required String name,
  required Future<SpatialMadePhoto?> Function() known,
  required Future<String?> Function() launch,
  required Future<ImageProvider?> Function(String path) existing,
  required void Function(SpatialMadePhoto photo) open,
}) async {
  SpatialMadePhoto? found;
  try {
    found = await known().timeout(_lookupWait);
  } catch (error) {
    _log.info('The 3D photos made from $name could not be looked for: $error');
  }
  if (!context.mounted) {
    return;
  }
  if (found != null) {
    open(found);
    return;
  }
  final id = await launch();
  if (id == null || !context.mounted) {
    return;
  }
  final made = await showDialog<SpatialMadePhoto>(
    context: context,
    barrierDismissible: false,
    builder: (context) => SpatialConversionDialog(
      jobId: id,
      name: name,
      photoOf: (job) => spatialJobPhoto(job, existing: existing),
    ),
  );
  if (made != null && context.mounted) {
    open(made);
  }
}

/// The dialog that follows the job [jobId] of the photo named [name] until its 3D photo can open (see the top of this
/// file); it closes with that photo, or with nothing once cancelled
class SpatialConversionDialog extends ConsumerStatefulWidget {
  const SpatialConversionDialog({super.key, required this.jobId, required this.name, required this.photoOf});

  final String jobId;
  final String name;

  /// The 3D photo the job ended with (see [spatialJobPhoto])
  final Future<SpatialMadePhoto?> Function(ConversionJob job) photoOf;

  @override
  ConsumerState<SpatialConversionDialog> createState() => _SpatialConversionDialogState();
}

class _SpatialConversionDialogState extends ConsumerState<SpatialConversionDialog> {
  /// Read in initState: closed from outside, the dialog cancels its job from dispose, where ref is no longer read
  late final ConversionQueueNotifier _queue;

  /// Why no 3D photo opens: the words of the failure or of the skip, shown with Close
  String? _error;

  /// The job ended well: its file is being read
  var _opening = false;
  var _closed = false;

  /// The job ended, or the queue forgot it: nothing to cancel
  var _jobEnded = false;

  @override
  void initState() {
    super.initState();
    _queue = ref.read(conversionQueueProvider.notifier);
    // A job that ended before the first frame (a version with the same settings, a photo skipped)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _onJob(ref.read(conversionQueueProvider).byId(widget.jobId));
      }
    });
  }

  @override
  void dispose() {
    // Closed by anything else than its buttons (the route removed from outside): the job does not go on unseen. After
    // the frame: a cancel changes the queue, which no provider may do while the tree is being built or torn down
    if (!_closed) {
      _closed = true;
      if (!_jobEnded) {
        final queue = _queue;
        final id = widget.jobId;
        scheduleMicrotask(() => queue.cancel(id));
      }
    }
    super.dispose();
  }

  void _cancelJob() {
    if (!_jobEnded) {
      _queue.cancel(widget.jobId);
    }
  }

  void _close([SpatialMadePhoto? photo]) {
    if (_closed) {
      return;
    }
    _closed = true;
    Navigator.of(context).pop(photo);
  }

  /// Cancel, Escape: the job is cancelled while it runs, the dialog closes
  void _cancel() {
    _cancelJob();
    _close();
  }

  void _onJob(ConversionJob? job) {
    if (_closed || _opening || _error != null) {
      return;
    }
    if (job == null) {
      // Forgotten by the queue (Clear finished in the panel)
      _close();
      return;
    }
    final t = context.t;
    switch (job.state) {
      case ConversionState.done:
        unawaited(_open(job));
      case ConversionState.skipped when job.existingVersionPath != null:
        unawaited(_open(job));
      case ConversionState.skipped:
        setState(
          () => _error = conversionSkipText(t, job.skipReason ?? ConversionSkipReason.unreachable, name: widget.name),
        );
      case ConversionState.failed:
        setState(
          () => _error = conversionFailureText(
            t,
            job.error ?? ImmersiveErrorCode.modelFailed,
            job.message,
            kind: job.kind,
          ),
        );
      case ConversionState.cancelled || ConversionState.paused:
        _close();
      default:
        break;
    }
  }

  Future<void> _open(ConversionJob job) async {
    final t = context.t;
    setState(() => _opening = true);
    SpatialMadePhoto? photo;
    try {
      photo = await widget.photoOf(job);
    } catch (error) {
      _log.warning('The 3D photo of ${widget.name} could not be read: $error');
    }
    if (!mounted || _closed) {
      return;
    }
    if (photo == null) {
      setState(() {
        _opening = false;
        _error = t.scaffold_body_error_occurred;
      });
      return;
    }
    _close(photo);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _error != null ? _close() : _cancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(conversionQueueProvider.select((queue) => queue.byId(widget.jobId)), (_, job) => _onJob(job));
    final t = context.t;
    final theme = Theme.of(context);
    final job = ref.watch(conversionQueueProvider.select((queue) => queue.byId(widget.jobId)));
    _jobEnded = job == null || job.state.isEnded;
    final error = _error;
    final lines = <String>[
      if (job != null && error == null && !_opening) ...[
        conversionStageText(t, job) ?? conversionStateText(t, job),
        if (job.waitingFor case final wait?)
          conversionWaitText(t, wait, shortfall: job.gpuShortfall, kind: job.kind)
        else
          ?conversionProgressText(t, job, job.remaining),
      ],
    ];
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        key: const Key('spatial_conversion_dialog'),
        title: Text(t.spatial_2_5d),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.name, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              if (error != null)
                Text(
                  error,
                  key: const Key('spatial_conversion_error'),
                  style: TextStyle(color: theme.colorScheme.error),
                )
              else ...[
                LinearProgressIndicator(
                  key: const Key('spatial_conversion_bar'),
                  value: job == null || _opening ? null : conversionBarValue(job),
                ),
                for (final line in lines) ...[const SizedBox(height: 8), Text(line)],
              ],
            ],
          ),
        ),
        actions: [
          if (error != null)
            TextButton(key: const Key('spatial_conversion_close'), onPressed: _close, child: Text(t.close))
          else
            TextButton(key: const Key('spatial_conversion_cancel'), onPressed: _cancel, child: Text(t.cancel)),
        ],
      ),
    );
  }
}
