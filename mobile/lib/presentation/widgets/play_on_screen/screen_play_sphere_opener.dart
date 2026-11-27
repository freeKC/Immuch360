// In the asset viewer of a big screen: opens the 360° view of the asset a phone's play asked for
// (screenPlaySphereRequestProvider), as the 360° button would, once the viewer shows that asset. On the TV and the
// computers that is the 360° video player; on the Meta Quest, the immersive viewer the user chose with "In the
// headset". The 360° photos of the TV and the computers open in the 360° photo viewer directly (screen_player.provider.dart).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_native_viewers.dart';

class ScreenPlaySphereOpener extends ConsumerStatefulWidget {
  const ScreenPlaySphereOpener({super.key});

  @override
  ConsumerState<ScreenPlaySphereOpener> createState() => _ScreenPlaySphereOpenerState();
}

class _ScreenPlaySphereOpenerState extends ConsumerState<ScreenPlaySphereOpener> {
  @override
  void initState() {
    super.initState();
    _later();
  }

  void _later() => WidgetsBinding.instance.addPostFrameCallback((_) => _open());

  void _open() {
    if (!mounted) {
      return;
    }
    final wanted = ref.read(screenPlaySphereRequestProvider);
    final asset = ref.read(assetViewerProvider).currentAsset;
    if (wanted == null || asset == null || asset.remoteId?.toLowerCase() != wanted) {
      return;
    }
    ref.read(screenPlaySphereRequestProvider.notifier).state = null;
    unawaited(open360View(context, ref, asset));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(screenPlaySphereRequestProvider, (_, _) => _later());
    ref.listen(assetViewerProvider.select((state) => state.currentAsset), (_, _) => _later());
    return const SizedBox.shrink();
  }
}
