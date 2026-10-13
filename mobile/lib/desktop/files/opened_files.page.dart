import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

/// Several files, or a folder, opened with the program at once (see DesktopOpenFilesHandler): their photos and videos
/// as the page of a folder of the library shows them, by date, each with its 360° badge, without joining the library.
/// A photo or a video opens in the viewer, which goes from one to the next. Read only: nothing here changes the files.
///
/// [files] are read while the page waits; [title] is the name of the folder that holds them all, or null when none
/// does but the root of a drive, for the page to count them.
@RoutePage()
class OpenedFilesPage extends StatelessWidget {
  const OpenedFilesPage({super.key, this.title, required this.files});

  final String? title;
  final Future<OpenedBatch> files;

  @override
  Widget build(BuildContext context) => FutureBuilder<OpenedBatch>(
    future: files,
    builder: (context, snapshot) {
      final batch = snapshot.data;
      final title = this.title ?? (batch == null ? '' : context.t.items_count(count: batch.files.length));
      if (batch == null || batch.files.isEmpty) {
        final Widget body = switch (batch) {
          null when snapshot.hasError => Text(context.t.failed_to_load_assets),
          null => const CircularProgressIndicator(),
          _ => Text(batch.fromFolder ? context.t.empty_folder : context.t.no_assets_to_show),
        };
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: Center(child: body),
        );
      }
      // A scope per batch: a page that gets other files (a new drop while it is open) shows them, not the files of
      // the timeline it made first, which an override keeps
      return ProviderScope(
        key: ObjectKey(batch),
        overrides: [
          timelineServiceProvider.overrideWith((ref) {
            final service = ref
                .watch(timelineFactoryProvider)
                .fromAssetsWithBuckets(batch.assets, TimelineOrigin.deepLink);
            ref.onDispose(service.dispose);
            return service;
          }),
        ],
        child: Timeline(appBar: MesmerizingSliverAppBar(title: title), bottomSheet: null, readOnly: true),
      );
    },
  );
}
