// Immuch360: the Cast action of the asset viewer opens "Play on..." (play_on_asset.dart) on a phone, for an asset of
// the server, and is absent on a TV, the Quest and for an asset that has no request.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/presentation/actions/cast.action.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';

import '../presentation_context.dart';

final _asset = RemoteAsset(
  id: '3f2504e0-4f89-11d3-9a0c-0305e82c3301',
  name: 'IMG_0001.jpg',
  ownerId: 'a1b2c3d4-0000-4000-8000-00000000abcd',
  checksum: 'c',
  type: AssetType.image,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  isEdited: false,
);

class _Viewer extends AssetViewerStateNotifier {
  @override
  AssetViewerState build() => AssetViewerState(currentAsset: _asset);
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  List<Override> overrides({bool tv = false, bool quest = false, bool hasRequest = true}) => [
    assetViewerProvider.overrideWith(_Viewer.new),
    tvModeProvider.overrideWithValue(tv),
    isHorizonOsProvider.overrideWith((_) async => quest),
    playOnAssetRequestProvider.overrideWithValue(
      (asset) => hasRequest
          ? PlayOnRequest.ofAsset(asset, userId: _asset.ownerId, endpoints: const [], serverName: 'photos')
          : null,
    ),
  ];

  group('CastAction', () {
    testWidgets('on a phone, an asset of the server offers Play on', (tester) async {
      await tester.pumpTestWidget(context, const ActionIconButton(action: CastAction()), overrides: overrides());
      await tester.pump();

      expect(find.byIcon(Icons.cast_rounded), findsOneWidget);
    });

    testWidgets('absent on a TV and on the Quest, which are the screens', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: CastAction()),
        overrides: overrides(tv: true),
      );
      await tester.pump();
      expect(find.byIcon(Icons.cast_rounded), findsNothing);
    });

    testWidgets('absent on the Quest', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: CastAction()),
        overrides: overrides(quest: true),
      );
      await tester.pump();
      expect(find.byIcon(Icons.cast_rounded), findsNothing);
    });

    testWidgets('absent for an asset with no request', (tester) async {
      await tester.pumpTestWidget(
        context,
        const ActionIconButton(action: CastAction()),
        overrides: overrides(hasRequest: false),
      );
      await tester.pump();
      expect(find.byIcon(Icons.cast_rounded), findsNothing);
    });
  });
}
