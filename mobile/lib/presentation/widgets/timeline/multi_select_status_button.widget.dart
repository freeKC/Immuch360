import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/selection/desktop_selection.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

class MultiSelectStatusButton extends ConsumerWidget {
  const MultiSelectStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectCount = ref.watch(multiSelectProvider.select((s) => s.selectedAssets.length));
    final button = ElevatedButton.icon(
      onPressed: () => ref.read(multiSelectProvider.notifier).reset(),
      icon: Icon(Icons.close_rounded, color: context.colorScheme.onPrimary),
      label: Text(
        // Immuch360 Desktop: "12 selected", and the keys and clicks of a selection as its hint
        CurrentPlatform.isDesktop ? context.t.selected_count(count: selectCount) : selectCount.toString(),
        style: context.textTheme.titleMedium?.copyWith(height: 2.5, color: context.colorScheme.onPrimary),
      ),
    );
    return withDesktopSelectionHint(context, button);
  }
}
