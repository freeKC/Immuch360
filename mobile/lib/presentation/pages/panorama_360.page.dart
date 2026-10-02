import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

/// Every 360° photo and video of the user, newest first, opened from the Library tab. Without a server, those of this
/// device: the ones whose files declare it, and the ones the user chose to view as 360° (see localPanoramaIdsProvider).
@RoutePage()
class Panorama360Page extends StatelessWidget {
  const Panorama360Page({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWith((ref) {
          final factory = ref.watch(timelineFactoryProvider);
          final TimelineService timelineService;
          if (ref.watch(localSessionProvider)) {
            timelineService = factory.localPanorama360(ref.watch(localPanoramaIdsProvider));
          } else {
            final user = ref.watch(currentUserProvider);
            if (user == null) {
              throw Exception('User must be logged in to access 360° photos and videos');
            }
            timelineService = factory.panorama360(user.id);
          }
          ref.onDispose(timelineService.dispose);
          return timelineService;
        }),
      ],
      child: Timeline(appBar: MesmerizingSliverAppBar(title: context.t.library_360)),
    );
  }
}
