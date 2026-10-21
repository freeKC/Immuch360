// The details of an asset with the remote control layout: read only (the description as text, no field and so no
// keyboard on the way down, no pencil for the date or the place, no "Add a location", the stars of the rating without
// Clear) and the focus on their first row as they open; a phone keeps the field and the pencil.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/user_metadata.model.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/date_time_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<RemoteAsset> pumpDetails(WidgetTester tester, {required bool tvMode, String description = ''}) async {
    final asset = RemoteAssetFactory.create(ownerId: context.currentUser.id, width: 4000, height: 3000);
    final details = SingleChildScrollView(child: AssetDetails(asset: asset, minHeight: 400));
    await tester.pumpTestWidget(
      context,
      // The remote control layout of main.dart: directional navigation, where every row of the details takes the focus
      TvShell(enabled: tvMode, child: details),
      overrides: [
        tvModeProvider.overrideWithValue(tvMode),
        assetExifProvider(asset).overrideWith((ref) => Stream.value(ExifInfo(description: description, rating: 3))),
        Store.people.forAsset(asset.id).overrideWith((ref) => Stream.value(const [])),
        Store.userMetadata.preferences().overrideWith((ref) => Stream.value(const Preferences(ratingsEnabled: true))),
        albumsContainingAssetProvider(asset.id).overrideWith((ref) async => const []),
      ],
    );
    // The asset of the viewer, which the user owns: the actions on it (the pencils) are there to hide
    ProviderScope.containerOf(
      tester.element(find.byType(AssetDetails)),
    ).read(assetViewerProvider.notifier).setAsset(asset);
    await tester.pumpAndSettle();
    return asset;
  }

  bool focusIn<T extends Widget>() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<T>() != null;

  testWidgets('on a TV the description is text, and no pencil nor "Add a location" shows', (tester) async {
    await pumpDetails(tester, tvMode: true, description: 'Low tide in Brest');

    expect(find.text('Low tide in Brest'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.edit), findsNothing, reason: 'the date pencil');
    expect(find.text('Add a location'), findsNothing);
    expect(find.byIcon(Icons.star_rounded), findsNWidgets(5), reason: 'the rating is shown');
    expect(find.text('Clear rating'), findsNothing);
  });

  testWidgets('on a TV no description, no row: no "Add Description..."', (tester) async {
    await pumpDetails(tester, tvMode: true);

    expect(find.text('Add Description...'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('on a TV the focus starts on the date, and Down goes on to the details without a keyboard', (
    tester,
  ) async {
    await pumpDetails(tester, tvMode: true, description: 'Low tide in Brest');
    expect(focusIn<DateTimeDetails>(), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(focusIn<TechnicalDetails>(), isTrue);
    expect(find.byType(EditableText), findsNothing);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('a phone keeps the description field, the date pencil and Clear, and its focus where it was', (
    tester,
  ) async {
    await pumpDetails(tester, tvMode: false);

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Add Description...'), findsOneWidget);
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.text('Clear rating'), findsOneWidget);
    expect(focusIn<DateTimeDetails>(), isFalse);
  });
}
