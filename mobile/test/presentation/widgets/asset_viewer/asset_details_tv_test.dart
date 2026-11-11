// The details of an asset with the remote control layout: read only (the description as text, no field and so no
// keyboard on the way down, no pencil for the date or the place, no "Add a location", the stars of the rating without
// Clear, the tags without remove nor "Add tag" and all shown) and the focus on their first row as they open; a phone
// keeps the field, the pencil and the tag actions.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/domain/models/user_metadata.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/date_time_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/tag_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/technical_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
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

  Future<RemoteAsset> pumpDetails(
    WidgetTester tester, {
    required bool tvMode,
    String description = '',
    List<Tag> tags = const [],
  }) async {
    final asset = RemoteAssetFactory.create(ownerId: context.currentUser.id, width: 4000, height: 3000);
    final details = SingleChildScrollView(child: AssetDetails(asset: asset, minHeight: 400));
    final overrides = [
      tvModeProvider.overrideWithValue(tvMode),
      assetExifProvider(asset).overrideWith((ref) => Stream.value(ExifInfo(description: description, rating: 3))),
      Store.people.forAsset(asset.id).overrideWith((ref) => Stream.value(const [])),
      Store.userMetadata.preferences().overrideWith(
        (ref) => Stream.value(Preferences(ratingsEnabled: true, tagsEnabled: tags.isNotEmpty)),
      ),
      Store.tags.forAsset(asset.id).overrideWith((ref) async => tags),
      albumsContainingAssetProvider(asset.id).overrideWith((ref) async => const []),
    ];
    // One scope for the context's overrides and these, as main.dart has one: the tag actions read the preferences
    // through a provider that declares no dependency, which a nested scope overriding them refuses
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [...context.overrides, ...overrides],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              // The remote control layout of main.dart: directional navigation, where every row of the details takes
              // the focus
              home: Scaffold(
                body: TvShell(enabled: tvMode, child: details),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
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

  // More tags than the collapsed list of a phone holds (140 dp), with long names
  final manyTags = [for (var i = 1; i <= 14; i++) Tag(id: 'tag-$i', value: 'Brittany coast trip, day $i')];

  testWidgets('on a TV the tags show all, without remove nor "Add tag", and Down reaches them under the focus ring', (
    tester,
  ) async {
    await pumpDetails(tester, tvMode: true, tags: manyTags);

    final chips = find.byType(InputChip);
    expect(chips, findsNWidgets(manyTags.length));
    expect(find.byIcon(Icons.close), findsNothing, reason: 'no remove on a chip');
    expect(find.text('Add tag'), findsNothing);
    expect(find.text('View more'), findsNothing, reason: 'nothing is collapsed');
    expect(find.descendant(of: find.byType(TagDetails), matching: find.byType(ShaderMask)), findsNothing);
    final area = tester.getRect(find.byType(TagDetails));
    final last = tester.getRect(chips.last);
    expect(area.top <= last.top && last.bottom <= area.bottom, isTrue, reason: 'the last chip is laid out in the row');

    for (var i = 0; i < 12 && !focusIn<TagDetails>(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(focusIn<TagDetails>(), isTrue, reason: 'Down goes from the rows above to the tags');
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<InputChip>(), isNotNull);
    final ring = tester.state<TvFocusRingState>(find.byType(TvFocusRing)).ringRect;
    final focused = FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<InputChip>()!;
    expect(ring, isNotNull);
    expect(ring!.overlaps(tester.getRect(find.byWidget(focused))), isTrue, reason: 'the ring frames the focused chip');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusIn<TagDetails>(), isTrue, reason: 'Down goes on through the chips');
  });

  testWidgets('a phone keeps remove on each tag and "Add tag", and collapses a long list behind View more', (
    tester,
  ) async {
    await pumpDetails(tester, tvMode: false, tags: manyTags);

    expect(find.byType(InputChip), findsNWidgets(manyTags.length));
    expect(find.byIcon(Icons.close), findsNWidgets(manyTags.length));
    expect(find.text('Add tag'), findsOneWidget);
    expect(find.text('View more'), findsOneWidget);
  });
}
