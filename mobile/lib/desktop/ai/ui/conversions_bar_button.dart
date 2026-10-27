// The button of the app bar of a computer for the 3D conversions (design-final 2026-10-26, section 5, point 4): an icon
// with the number of jobs waiting or under way, which opens the panel of the conversions. It shows once the queue holds
// a job, finished ones included, so that their results stay one click away; the AI features turned off hide it, like
// every AI button.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/generated/translations.g.dart';

class DesktopConversionsBarButton extends ConsumerWidget {
  const DesktopConversionsBarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(aiFeaturesEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final jobs = ref.watch(conversionQueueProvider.select((queue) => (all: queue.jobs.length, pending: queue.pending)));
    final paused = ref.watch(conversionQueueProvider.select((queue) => queue.isPaused));
    if (jobs.all == 0) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const Key('ai_conversions_button'),
      tooltip: context.t.ai_immersive_conversions,
      onPressed: () => showConversionsPanel(context),
      icon: Badge(
        isLabelVisible: jobs.pending > 0 || paused,
        backgroundColor: paused ? Theme.of(context).colorScheme.error : null,
        label: Text(paused ? '!' : '${jobs.pending}'),
        child: const Icon(Icons.view_in_ar_outlined),
      ),
    );
  }
}
