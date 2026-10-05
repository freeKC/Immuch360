import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/panorama_360/panorama_360_filter_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

/// Every 360° photo and video the app knows of, newest first, opened from the Library tab: those the server flags,
/// the raw files of 360° cameras, those the user chose to view as 360°, and those of this device whose files declare
/// it, each once wherever its copies are (see Panorama360ListService). The bar above the grid narrows the list down,
/// and the immersive viewer of the Meta Quest moves through the list as filtered.
@RoutePage()
class Panorama360Page extends ConsumerStatefulWidget {
  const Panorama360Page({super.key});

  @override
  ConsumerState<Panorama360Page> createState() => _Panorama360PageState();
}

class _Panorama360PageState extends ConsumerState<Panorama360Page> {
  @override
  void initState() {
    super.initState();
    // The device files the server knows nothing about: read in a session with a server too. Cheap once done, the
    // records remember what was read.
    unawaited(ref.read(localPanoramaScanProvider)());
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          // Built once: a new filter gives a new view of the same list, never a new service under an open viewer
          final service = TimelineService(ref.watch(panorama360ListProvider).timelineQuery);
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
      child: Timeline(
        appBar: MesmerizingSliverAppBar(title: context.t.library_360),
        topSliverWidget: const Panorama360FilterBar(),
        topSliverWidgetHeight: Panorama360FilterBar.estimatedHeight,
      ),
    );
  }
}
