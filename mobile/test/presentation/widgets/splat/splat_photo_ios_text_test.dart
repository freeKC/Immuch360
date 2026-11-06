// What a splat photo says on iOS about where its scene is explored (App Store guideline 2.3.10: the iOS app names no
// other mobile platform): the details row and the line said as the photo opens give a computer or a headset, while
// the TVs keep the text that names the Android phones and tablets and the Meta Quest 3 and 3S.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_photo_button.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/splat/splat_photo.provider.dart';

import '../../../domain/splat_photo/splat_photo_fixtures.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

const _iosText = 'Splat scene: explore it on a computer or in a headset';
const _tvText = 'Splat scene: explore it on a computer, an Android phone or tablet, or a Meta Quest 3 or 3S';

/// The names of other mobile platforms an iOS text must not hold
final _otherPlatforms = RegExp(r'\b(Android|Google|Meta|Quest|Horizon|Samsung|Galaxy|Tizen|webOS|LG)\b');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PresentationContext context;
  final xmp = SplatPhotoXmp.findIn(splatPhotoFixture('ok_v4.jpg'))!;
  final photo = RemoteAssetFactory.create(name: 'salon_splat.jpg');

  List<Override> overrides({SplatPhotoExplore? explore}) => [
    splatPhotoProvider(photo).overrideWith((ref) async => xmp),
    assetExifProvider(photo).overrideWith((ref) => Stream.value(null)),
    if (explore != null) splatPhotoExploreProvider.overrideWithValue(explore),
  ];

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  test('iOS explores the scenes elsewhere, as before', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(splatPhotoExploreProvider), SplatPhotoExplore.elsewhere);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on iOS the details row says a computer or a headset, and names no other platform', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // Reset within the test, even when an expectation fails: the binding checks it before the tear downs run
    try {
      await tester.pumpTestWidget(context, SplatPhotoDetailsTile(asset: photo), overrides: overrides());

      expect(find.byKey(splatPhotoDetailsKey), findsOneWidget);
      expect(find.text(_iosText), findsOneWidget);
      expect(find.textContaining(_otherPlatforms), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on iOS the line said as the photo opens says a computer or a headset', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpTestWidget(context, SplatPhotoElsewhereNotice(asset: photo), overrides: overrides());

      expect(find.widgetWithText(SnackBar, _iosText), findsOneWidget);
      expect(find.textContaining(_otherPlatforms), findsNothing);
      await tester.pump(splatPhotoNoticeDuration);
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a TV keeps the text that names the Android phones and tablets and the Meta Quest', (tester) async {
    await tester.pumpTestWidget(
      context,
      SplatPhotoDetailsTile(asset: photo),
      overrides: overrides(explore: SplatPhotoExplore.elsewhere),
    );

    expect(find.text(_tvText), findsOneWidget);
    expect(find.text(_iosText), findsNothing);
  });

  testWidgets('the Quest builds of the Meta Horizon Store keep their own line', (tester) async {
    await tester.pumpTestWidget(
      context,
      SplatPhotoDetailsTile(asset: photo),
      overrides: overrides(explore: SplatPhotoExplore.elsewhereStore),
    );

    expect(find.text('Splat scene: explore it on a computer, an Android phone or tablet'), findsOneWidget);
  });

  test('the English of every iOS only text names no other mobile platform', () {
    final en = jsonDecode(File('../i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    final ios = en.entries.where((entry) => entry.key.endsWith('_ios') && entry.value is String).toList();

    expect(
      ios.map((entry) => entry.key),
      containsAll(['splat_photo_open_elsewhere_ios', 'ai_immersive_open_on_quest_ios', 'pairing_err_webos_ios']),
    );
    for (final entry in ios) {
      expect(_otherPlatforms.hasMatch(entry.value as String), isFalse, reason: '${entry.key}: ${entry.value}');
    }
  });
}
