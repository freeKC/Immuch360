// Where the splat viewer of the computers, phones and tablets is offered (plan of 2 November 2026): the computers, the
// Android phones and tablets once Android has said this is no headset, never a TV; the headset keeps its own viewer.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_gate.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/infrastructure/splat/pigeon_splat_viewer_host.dart';
import 'package:immich_mobile/platform/splat_viewer_api.g.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
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

  group('the free space a preparation reads (review of 2 November 2026)', () {
    test('the computers read it with the reader of the AI components', () async {
      Directory? asked;
      final container = ProviderContainer(
        overrides: [
          aiFreeSpaceProvider.overrideWithValue((folder) async {
            asked = folder;
            return AiFreeSpace(free: 123456, volume: 'D:');
          }),
          splatViewerHostProvider.overrideWithValue(_NoHost()),
        ],
      );
      addTearDown(container.dispose);
      final read = container.read(splatFreeBytesProvider)!;
      expect(await read(Directory('/cache/splat_viewer')), 123456);
      expect(asked!.path, '/cache/splat_viewer');
    });

    test('Android asks StatFs through the splat viewer API; -1 or a failure is no answer', () async {
      final api = _Api();
      final container = ProviderContainer(
        overrides: [splatViewerHostProvider.overrideWithValue(PigeonSplatViewerHost(api: api, listen: false))],
      );
      addTearDown(container.dispose);
      final read = container.read(splatFreeBytesProvider)!;
      api.free = 5 << 30;
      expect(await read(Directory('/data/user/0/app/cache/splat_viewer')), 5 << 30);
      expect(api.asked, '/data/user/0/app/cache/splat_viewer');
      api.free = -1;
      expect(await read(Directory('/x')), isNull);
      api.fails = true;
      expect(await read(Directory('/x')), isNull);
    });

    test('elsewhere nothing is read', () {
      final container = ProviderContainer(overrides: [splatViewerHostProvider.overrideWithValue(null)]);
      addTearDown(container.dispose);
      expect(container.read(splatFreeBytesProvider), isNull);
    });
  });
}

class _NoHost implements SplatViewerHost {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements SplatViewerApi {
  int free = 0;
  bool fails = false;
  String? asked;

  @override
  Future<int> freeBytes(String folder) async {
    if (fails) {
      throw StateError('no channel');
    }
    asked = folder;
    return free;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
