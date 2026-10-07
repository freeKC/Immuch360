import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_badges.widget.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_clip_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// The clips a Tapo camera recorded on [day], under the hours of the camera's time. A clip is fetched from the camera
/// before it plays (the camera cannot serve a part of one), with its progress and a Cancel; it then opens in the video
/// page of the shares, alone (its neighbours are not fetched).
@RoutePage()
class CameraDayPage extends ConsumerStatefulWidget {
  const CameraDayPage({super.key, required this.sourceId, required this.day});

  final String sourceId;

  /// "yyyy-mm-dd", the date of the camera where it stands (its own time zone)
  final String day;

  @override
  ConsumerState<CameraDayPage> createState() => _CameraDayPageState();
}

class _CameraDayPageState extends ConsumerState<CameraDayPage> {
  (String, String) get _key => (widget.sourceId, widget.day);

  Future<void> _open(TapoRecordings recordings, TapoClip clip) async {
    if (!recordings.isFetched(clip)) {
      final fetched = await showModalBottomSheet<bool>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        builder: (context) => _FetchSheet(
          recordings: recordings,
          clip: clip,
          host: ref.read(networkSourceProvider(widget.sourceId))?.host ?? '',
        ),
      );
      ref.invalidate(tapoCameraCacheBytesProvider(widget.sourceId));
      if (!mounted) {
        return;
      }
      setState(() {});
      if (fetched != true) {
        return;
      }
    }
    await context.pushRoute(NetworkVideoRoute(sourceId: widget.sourceId, path: clip.path));
  }

  Future<void> _offerDelete(TapoRecordings recordings, TapoClip clip) async {
    final delete = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListTile(
          key: const Key('camera_clip_delete_copy'),
          leading: const Icon(Icons.delete_outline),
          title: Text(context.t.camera_clip_delete_copy),
          onTap: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (delete != true) {
      return;
    }
    await recordings.deleteCopy(clip);
    ref.invalidate(tapoCameraCacheBytesProvider(widget.sourceId));
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.locale.toLanguageTag();
    final date = DateTime.tryParse(widget.day);
    final source = ref.watch(networkSourceProvider(widget.sourceId));
    final recordings = ref.watch(tapoRecordingsProvider(widget.sourceId)).valueOrNull;
    final clips = ref.watch(tapoCameraClipsProvider(_key));
    final tvMode = ref.watch(tvModeProvider);
    final time = DateFormat.Hms(locale);
    final hour = DateFormat.Hm(locale);

    final children = <Widget>[];
    switch (clips) {
      case AsyncData(:final value) when value.isEmpty || recordings == null:
        children.add(_Note(key: const Key('camera_day_empty'), text: context.t.camera_day_empty));
      case AsyncData(:final value):
        int? lastHour;
        for (final (index, clip) in value.indexed) {
          final local = cameraLocalTime(source?.camera, clip.start);
          if (local.hour != lastHour) {
            lastHour = local.hour;
            children.add(
              Padding(
                key: Key('camera_hour_${local.hour}'),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  hour.format(DateTime.utc(local.year, local.month, local.day, local.hour)),
                  style: context.textTheme.titleSmall?.copyWith(
                    color: context.primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }
          final fetched = recordings!.isFetched(clip);
          children.add(
            CameraClipTile(
              clip: clip,
              time: time.format(local),
              thumbnail: () => recordings.thumbnail(clip),
              isFetched: fetched,
              autofocus: tvMode && index == 0,
              onTap: () => unawaited(_open(recordings, clip)),
              // Touch only: a remote clears the whole cache from the camera page
              onLongPress: fetched && !tvMode ? () => unawaited(_offerDelete(recordings, clip)) : null,
            ),
          );
        }
      case AsyncError(:final error):
        children.add(
          _Note(
            key: const Key('camera_day_error'),
            text: cameraErrorText(context, error, host: source?.host ?? ''),
            isError: true,
          ),
        );
      default:
        children.add(
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
    }

    Future<void> refresh() => ref.read(tapoCameraClipsProvider(_key).notifier).refresh();

    return Scaffold(
      appBar: AppBar(
        title: Text(date == null ? widget.day : DateFormat.yMMMMEEEEd(locale).format(date)),
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(
            key: const Key('camera_day_refresh'),
            tooltip: context.t.refresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => unawaited(refresh()),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: ListView(padding: const EdgeInsets.only(bottom: 32), children: children),
        ),
      ),
    );
  }
}

/// Fetches a clip with its progress and a Cancel; pops true once the clip is on this device, false when cancelled.
/// A failure stays on the sheet until it is closed.
class _FetchSheet extends StatefulWidget {
  const _FetchSheet({required this.recordings, required this.clip, required this.host});

  final TapoRecordings recordings;
  final TapoClip clip;
  final String host;

  @override
  State<_FetchSheet> createState() => _FetchSheetState();
}

class _FetchSheetState extends State<_FetchSheet> {
  final _cancel = Completer<void>();
  double _progress = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    try {
      await widget.recordings.fetch(
        widget.clip,
        cancel: _cancel.future,
        onProgress: (progress) {
          if (mounted) {
            setState(() => _progress = progress);
          }
        },
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on TapoCameraException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.kind == TapoErrorKind.cancelled) {
        Navigator.of(context).pop(false);
      } else {
        setState(() => _error = error);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  void _stop() {
    if (_error != null) {
      Navigator.of(context).pop(false);
    } else if (!_cancel.isCompleted) {
      _cancel.complete();
    }
  }

  @override
  void dispose() {
    if (!_cancel.isCompleted) {
      _cancel.complete();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _stop();
        }
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error == null) ...[
                Text(
                  context.t.camera_clip_fetching(percent: (_progress * 100).round()),
                  key: const Key('camera_clip_fetching'),
                  style: context.textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              ] else
                Text(
                  context.t.camera_clip_fetch_failed(error: cameraErrorText(context, error, host: widget.host)),
                  key: const Key('camera_clip_fetch_failed'),
                  style: context.textTheme.bodyLarge?.copyWith(color: context.colorScheme.error),
                ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('camera_clip_cancel'),
                  autofocus: true,
                  onPressed: _stop,
                  child: Text(error == null ? context.t.cancel : context.t.close),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Text(
      text,
      style: context.textTheme.bodyMedium?.copyWith(
        color: isError ? context.colorScheme.error : context.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
