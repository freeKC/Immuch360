// At the start of the app, the 3D videos a quit, a crash or a restart of the computer stopped (video_jobs.json, release
// 49, store/m2/release-49/lots/video3d-plan.md section 4.5): each one put back in the queue of the conversions as
// paused, then a dialog per video, "A 3D video stopped at 42 %" with its name, Resume, Discard or Later. Resume goes on
// from its work folder; Discard deletes that folder; Later leaves it paused in the panel of the conversions, where
// Resume and Discard stay. A video whose original or folder is not there says so ("put it back, then Resume"). Nothing
// is asked while the AI features are off. The shell asks once the main page of the library shows (desktop_shell.dart),
// never over the splash, the welcome or the login pages.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:logging/logging.dart';

final _log = Logger('VideoResumeOffer');

/// What the user answered for a 3D video stopped
enum VideoResumeAnswer { resume, discard, later }

/// Puts the 3D videos stopped back in the queue and asks for each one, in [context] (the navigator of the window).
/// The answers, in the order of the videos.
Future<List<VideoResumeAnswer>> offerStoppedVideoJobs(BuildContext context, WidgetRef ref) async {
  final List<ConversionJob> stopped;
  try {
    if (!ref.read(aiFeaturesEnabledProvider)) {
      return const [];
    }
    stopped = await ref.read(conversionQueueProvider.notifier).restoreVideoJobs();
  } catch (error) {
    // A build or a test without the AI features set up: nothing to offer
    _log.info('No 3D video to offer to resume: $error');
    return const [];
  }
  final answers = <VideoResumeAnswer>[];
  for (final job in stopped) {
    if (!context.mounted) {
      break;
    }
    final answer =
        await showDialog<VideoResumeAnswer>(
          context: context,
          builder: (context) => VideoResumeDialog(job: job),
        ) ??
        VideoResumeAnswer.later;
    answers.add(answer);
    final queue = ref.read(conversionQueueProvider.notifier);
    switch (answer) {
      case VideoResumeAnswer.resume:
        queue.retry(job.id);
      case VideoResumeAnswer.discard:
        queue.cancel(job.id);
      case VideoResumeAnswer.later:
        break;
    }
  }
  if (answers.contains(VideoResumeAnswer.resume) && context.mounted) {
    unawaited(showConversionsPanel(context));
  }
  return answers;
}

/// "A 3D video was not finished": how far it went and its name, Resume first
class VideoResumeDialog extends StatelessWidget {
  const VideoResumeDialog({super.key, required this.job});

  final ConversionJob job;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      key: const Key('ai_video_resume_offer'),
      title: Text(t.ai_immersive_video_stopped_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Text(t.ai_immersive_video_stopped(percent: (job.progress * 100).floor()), key: const Key('ai_video_stopped')),
          Text(job.source.name, style: Theme.of(context).textTheme.titleSmall),
          // A download a quit stopped: the bytes kept, which "stopped at 0 %" does not say
          if (videoDownloadText(t, job) case final download?) Text(download, key: const Key('ai_video_offer_download')),
          if (videoMissingText(t, job) case final missing?)
            Text(
              missing,
              key: const Key('ai_video_offer_missing'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Text(t.ai_immersive_video_paused_kept),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('ai_video_offer_discard'),
          onPressed: () => Navigator.of(context).pop(VideoResumeAnswer.discard),
          child: Text(t.ai_immersive_video_discard),
        ),
        TextButton(
          key: const Key('ai_video_offer_later'),
          onPressed: () => Navigator.of(context).pop(VideoResumeAnswer.later),
          child: Text(t.ai_immersive_video_later),
        ),
        FilledButton(
          key: const Key('ai_video_offer_resume'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(VideoResumeAnswer.resume),
          child: Text(t.ai_immersive_video_resume),
        ),
      ],
    );
  }
}
