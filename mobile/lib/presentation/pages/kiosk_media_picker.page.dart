// The picker of the kiosk media (Settings, Advanced, "Kiosk mode", see KioskSettings): the 360° list of the Library
// tab, its filters and the row of the network shares included, where one tap picks a photo or a video and goes back
// with it (see KioskMedia) instead of opening it.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/panorama_360/panorama_360_filter_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/panorama_360/panorama_360_shares.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/panorama_360.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/widgets/common/selection_sliver_app_bar.dart';

/// See the top of this file. Goes back with the [KioskMedia] picked, or with nothing.
@RoutePage()
class KioskMediaPickerPage extends ConsumerStatefulWidget {
  const KioskMediaPickerPage({super.key});

  @override
  ConsumerState<KioskMediaPickerPage> createState() => _KioskMediaPickerPageState();
}

class _KioskMediaPickerPageState extends ConsumerState<KioskMediaPickerPage> {
  @override
  void initState() {
    super.initState();
    // As the 360° page: the device files the server knows nothing about
    unawaited(ref.read(localPanoramaScanProvider)());
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        // The selection mode of the timeline: a tap selects the asset rather than opening it, see _KioskPicker
        multiSelectProvider.overrideWith(
          () => MultiSelectNotifier(
            const MultiSelectState(selectedAssets: {}, lockedSelectionAssets: {}, forceEnable: true),
          ),
        ),
        timelineServiceProvider.overrideWith((ref) {
          final service = TimelineService(ref.watch(panorama360ListProvider).timelineQuery);
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
      child: const _KioskPicker(),
    );
  }
}

/// The 360° list under the overrides of the page: the first asset selected, or the file of a share tapped, is the pick
class _KioskPicker extends HookConsumerWidget {
  const _KioskPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A second tap while the page goes away picks nothing more
    final picked = useRef(false);
    void pick(KioskMedia media) {
      if (picked.value) {
        return;
      }
      picked.value = true;
      unawaited(context.maybePop(media));
    }

    ref.listen(multiSelectProvider.select((state) => state.selectedAssets), (_, selected) {
      if (selected.isNotEmpty) {
        pick(KioskMedia.asset(selected.first));
      }
    });
    return Timeline(
      appBar: SelectionSliverAppBar(pickTitle: context.t.kiosk_mode_choose_title),
      topSliverWidget: SliverMainAxisGroup(
        slivers: [
          const Panorama360FilterBar(),
          Panorama360SharesSection(onPick: (file) => pick(KioskMedia.shareFile(file))),
        ],
      ),
      topSliverWidgetHeight: Panorama360FilterBar.estimatedHeight,
    );
  }
}
