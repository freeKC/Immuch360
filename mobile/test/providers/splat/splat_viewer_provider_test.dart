// Where the splat viewer of the computers, phones and tablets is offered (plan of 2 November 2026): the computers, the
// Android phones and tablets once Android has said this is no headset, never a TV; the headset keeps its own viewer.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<(SplatDeviceClass?, bool)> classOf({
    TargetPlatform platform = TargetPlatform.android,
    bool? horizonOs,
    bool television = false,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    final answer = Completer<bool>();
    final container = ProviderContainer(
      overrides: [
        isHorizonOsProvider.overrideWith((ref) => answer.future),
        tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: television, isLowRamDevice: false)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(splatDeviceClassProvider, (_, _) {});
    if (horizonOs != null) {
      answer.complete(horizonOs);
      await container.read(isHorizonOsProvider.future);
    }
    final result = (container.read(splatDeviceClassProvider), container.read(splatFlatViewerProvider));
    debugDefaultTargetPlatformOverride = null;
    return result;
  }

  test('the computers show splats in their window, whatever Android would say', () async {
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
      expect(await classOf(platform: platform), (SplatDeviceClass.computer, true), reason: '$platform');
    }
  });

  test('an Android phone or tablet, once Android said it is no headset', () async {
    expect(await classOf(), (null, false), reason: 'not known yet');
    expect(await classOf(horizonOs: false), (SplatDeviceClass.phone, true));
  });

  test('the headset keeps its immersive viewer; a TV and iOS have no splat viewer', () async {
    expect(await classOf(horizonOs: true), (SplatDeviceClass.quest, false));
    expect(await classOf(horizonOs: false, television: true), (null, false));
    expect(await classOf(platform: TargetPlatform.iOS, horizonOs: false), (null, false));
  });
}
