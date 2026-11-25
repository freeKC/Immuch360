// "Compare" of a photo enhanced from a photo that is not a file of this computer (release 53): a photo of the Immich
// server, or of a share opened in the app. Its job read a copy of the original and deleted it when it ended; its
// result is in the folder of my choice, or beside its original on the share. The comparison fetches what it needs once
// asked: a copy of its own of the original (RecopiableOriginal), and a copy of the result when it is on the share,
// both among the copies of the AI, shown while they come with Cancel, and deleted once the comparison closes.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/creator/share_publisher.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart' show ImmersiveErrorCode;
import 'package:immich_mobile/desktop/ai/enhance/enhance_compare.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('EnhanceRemoteCompare');

/// The two files of a comparison, and what deletes the copies made for it
typedef EnhanceComparePair = ({String original, String enhanced, Future<void> Function() release});

/// Whether a done job of "Enhance (AI)" whose original is [source] can be compared once fetched: its original can be
/// copied again, and its result is on this computer ([written]) or on its share ([publish] saved there)
bool canCompareRemote(ConversionSource source, {String? written, SharePublish? publish}) =>
    source is RecopiableOriginal &&
    (written != null || (publish?.state == SharePublishState.saved && publish?.path != null));

/// Fetches the files of a comparison: the original of [source] copied again, the result at [written] on this computer,
/// or copied from its share by [publish]. Throws a ConversionException when a copy fails.
typedef EnhanceCompareFetcher =
    Future<EnhanceComparePair> Function(
      ConversionSource source, {
      String? written,
      SharePublish? publish,
      required bool Function() isCancelled,
    });

final enhanceCompareFetcherProvider = Provider<EnhanceCompareFetcher>((ref) {
  final shareSource = ref.watch(shareConversionSourceProvider);
  return (source, {written, publish, required isCancelled}) =>
      fetchEnhanceCompare(source, shareSource, written: written, publish: publish, isCancelled: isCancelled);
});

/// See [EnhanceCompareFetcher]; [shareSource] makes the source of a file of a share
Future<EnhanceComparePair> fetchEnhanceCompare(
  ConversionSource source,
  ShareFileSource Function(NetworkEntry entry) shareSource, {
  String? written,
  SharePublish? publish,
  required bool Function() isCancelled,
}) async {
  if (source is! RecopiableOriginal) {
    throw const ConversionException(ImmersiveErrorCode.sourceLost, 'The original cannot be copied again');
  }
  final made = <ConversionSource>[];
  Future<void> release() async {
    for (final copy in made) {
      try {
        await copy.release();
      } catch (error) {
        _log.fine('A copy of the comparison stays until the next start: $error');
      }
    }
  }

  try {
    final fresh = (source as RecopiableOriginal).recopy();
    made.add(fresh);
    final String original;
    if (fresh is ShareFileSource) {
      original = await fresh.copy(isCancelled: isCancelled);
    } else {
      final cancel = NativeCancelFlag();
      final watch = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (isCancelled()) {
          cancel.cancel();
        }
      });
      try {
        original = (await fresh.prepare(cancel)).path!;
      } finally {
        watch.cancel();
        cancel.free();
      }
    }
    String enhanced;
    if (written != null) {
      enhanced = written;
    } else {
      final path = publish?.path;
      if (publish == null || path == null) {
        throw const ConversionException(ImmersiveErrorCode.sourceLost, 'The enhanced photo is not known');
      }
      final result = shareSource(
        NetworkEntry(sourceId: publish.target.folder.sourceId, path: path, isDirectory: false),
      );
      made.add(result);
      enhanced = await result.copy(isCancelled: isCancelled);
    }
    return (original: original, enhanced: enhanced, release: release);
  } catch (_) {
    await release();
    rethrow;
  }
}

/// Opens the comparison of a done job of "Enhance (AI)" whose original is [source] (see the top of this file)
Future<void> showRemoteEnhanceCompare(
  BuildContext context,
  ConversionSource source, {
  String? written,
  SharePublish? publish,
}) => showDialog<void>(
  context: context,
  builder: (context) => RemoteEnhanceCompare(source: source, written: written, publish: publish),
);

/// The comparison once its files came: "Fetching..." with Cancel meanwhile, the reason when they did not come
class RemoteEnhanceCompare extends ConsumerStatefulWidget {
  const RemoteEnhanceCompare({super.key, required this.source, this.written, this.publish});

  final ConversionSource source;
  final String? written;
  final SharePublish? publish;

  @override
  ConsumerState<RemoteEnhanceCompare> createState() => _RemoteEnhanceCompareState();
}

class _RemoteEnhanceCompareState extends ConsumerState<RemoteEnhanceCompare> {
  EnhanceComparePair? _pair;
  Object? _error;
  var _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    try {
      final pair = await ref.read(enhanceCompareFetcherProvider)(
        widget.source,
        written: widget.written,
        publish: widget.publish,
        isCancelled: () => _closed,
      );
      if (_closed || !mounted) {
        await pair.release();
        return;
      }
      setState(() => _pair = pair);
    } catch (error) {
      _log.warning('The comparison of ${widget.source.name} could not be fetched: $error');
      if (!_closed && mounted) {
        setState(() => _error = error);
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    final pair = _pair;
    if (pair != null) {
      unawaited(pair.release());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pair = _pair;
    if (pair != null) {
      return EnhanceCompareDialog(originalPath: pair.original, enhancedPath: pair.enhanced);
    }
    final error = _error;
    return AlertDialog(
      key: const Key('ai_enhance_compare_fetch'),
      title: Text(t.ai_enhance_compare_title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: error == null
              ? [Text(t.ai_enhance_compare_fetching), const SizedBox(height: 12), const LinearProgressIndicator()]
              : [
                  Text(
                    t.ai_enhance_compare_failed(
                      reason: error is ConversionException ? (error.message ?? error.code.name) : '$error',
                    ),
                    key: const Key('ai_enhance_compare_failed'),
                  ),
                ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('ai_enhance_compare_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(error == null ? t.cancel : t.close),
        ),
      ],
    );
  }
}
