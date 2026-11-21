import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_preloader.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/factories/remote_asset_factory.dart';

class _Timeline extends Mock implements TimelineService {}

class _Completer extends ImageStreamCompleter {}

class _ImageProvider extends ImageProvider<_ImageProvider> {
  final completer = _Completer();

  @override
  Future<_ImageProvider> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    _ImageProvider key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(completer);
  }
}

void main() {
  testWidgets('a superseded preload cannot replace newer neighbors and dispose releases listeners', (tester) async {
    final timeline = _Timeline();
    final oldPrev = Completer<BaseAsset?>();
    final oldNext = Completer<BaseAsset?>();
    when(() => timeline.preloadAssets(any())).thenAnswer((_) async {});
    when(() => timeline.getAssetAsync(9)).thenAnswer((_) => oldPrev.future);
    when(() => timeline.getAssetAsync(11)).thenAnswer((_) => oldNext.future);
    when(() => timeline.getAssetAsync(19)).thenAnswer((_) async => RemoteAssetFactory.create(id: '19'));
    when(() => timeline.getAssetAsync(21)).thenAnswer((_) async => RemoteAssetFactory.create(id: '21'));
    final resolved = <String>[];
    final providers = <_ImageProvider>[];
    final preloader = AssetPreloader(
      timelineService: timeline,
      mounted: () => true,
      imageProvider: (asset, size, thumbnailSize) {
        resolved.add(asset.id);
        final provider = _ImageProvider();
        providers.add(provider);
        return provider;
      },
    );
    addTearDown(preloader.dispose);
    preloader.preload(10, const Size(960, 540));
    await tester.pump(Durations.medium4);
    preloader.preload(20, const Size(960, 540));
    await tester.pump(Durations.medium4);
    expect(resolved, ['19', '21']);
    oldPrev.complete(RemoteAssetFactory.create(id: '9'));
    oldNext.complete(RemoteAssetFactory.create(id: '11'));
    await tester.pump();
    expect(resolved, ['19', '21']);
    expect(providers.every((p) => p.completer.hasListeners), isTrue);
    preloader.dispose();
    expect(providers.every((p) => !p.completer.hasListeners), isTrue);
  });

  testWidgets('dispose invalidates asset lookups even before the viewer unmounts', (tester) async {
    final timeline = _Timeline();
    final reply = Completer<BaseAsset?>();
    when(() => timeline.preloadAssets(any())).thenAnswer((_) async {});
    when(() => timeline.getAssetAsync(any())).thenAnswer((_) => reply.future);
    var resolutions = 0;
    final preloader = AssetPreloader(
      timelineService: timeline,
      mounted: () => true,
      imageProvider: (_, _, _) {
        resolutions++;
        return _ImageProvider();
      },
    );
    preloader.preload(5, const Size(960, 540));
    await tester.pump(Durations.medium4);
    preloader.dispose();
    reply.complete(RemoteAssetFactory.create());
    await tester.pump();
    expect(resolutions, 0);
    preloader.preload(6, const Size(960, 540));
    await tester.pump(Durations.medium4);
    verify(() => timeline.preloadAssets(5)).called(1);
    verifyNever(() => timeline.preloadAssets(6));
  });
}
