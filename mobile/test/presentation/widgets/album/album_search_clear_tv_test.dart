// The Clear button of the album search with a remote control, from the work of Michael Cloutier (mlc70, branch
// feature/tv-search-navigation-upstream-20261027): the text field sits inside the entry of the TV keyboard, which
// takes no focus inside it, so on a TV Clear stands beside the entry, Right reaches it and OK clears the search.
// Phones keep Clear inside the field.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/album/album_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';
import 'package:mocktail/mocktail.dart';

import '../../../unit/presentation/presentation_context.dart';

/// No albums, and the queries the selector searches for
class _Albums extends RemoteAlbumNotifier {
  _Albums(this.queries);

  final List<String> queries;

  @override
  RemoteAlbumState build() => const RemoteAlbumState(albums: []);

  @override
  Future<void> refresh() async {}

  @override
  Future<List<RemoteAlbum>> sortAlbums(List<RemoteAlbum> albums, AlbumSortMode sortMode, {bool isReverse = false}) =>
      Future.value(albums);

  @override
  List<RemoteAlbum> searchAlbums(
    List<RemoteAlbum> albums,
    String query,
    String? userId, [
    QuickFilterMode filterMode = QuickFilterMode.all,
  ]) {
    queries.add(query);
    return albums;
  }
}

class _MockTvApi extends Mock implements TvApi {}

void main() {
  late PresentationContext context;
  late _MockTvApi tvApi;
  late List<String> queries;

  setUpAll(() {
    registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
  });

  setUp(() async {
    context = await PresentationContext.create();
    tvApi = _MockTvApi();
    queries = [];
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> pumpAlbums(WidgetTester tester, {required bool tvMode}) async {
    tester.view.physicalSize = tvMode ? const Size(1920, 1080) : const Size(1080, 2340);
    tester.view.devicePixelRatio = tvMode ? 2 : 3;
    addTearDown(tester.view.reset);
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
          overrides: [
            ...context.overrides,
            tvModeProvider.overrideWithValue(tvMode),
            tvApiProvider.overrideWithValue(tvApi),
            remoteAlbumProvider.overrideWith(() => _Albums(queries)),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              // As main.dart does
              builder: (context, child) => TvShell(enabled: tvMode, child: child!),
              home: Scaffold(
                body: CustomScrollView(slivers: [AlbumSelector(onAlbumSelected: (_) {})]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tvClear() => find.byKey(const Key('tv_album_search_clear'));

  Finder clearInField() => find.descendant(of: find.byType(TextField), matching: find.byIcon(Icons.clear_rounded));

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    return finder.evaluate().any((element) {
      var found = element == focused;
      if (!found) {
        focused.visitAncestorElements((ancestor) {
          found = ancestor == element;
          return !found;
        });
      }
      return found;
    });
  }

  testWidgets('on a TV Clear stands beside the entry, Right reaches it and OK clears the search', (tester) async {
    when(() => tvApi.editText(any())).thenAnswer((_) async => 'holidays');
    await pumpAlbums(tester, tvMode: true);
    expect(tvClear(), findsNothing, reason: 'nothing to clear yet');

    await tester.tap(find.byType(SearchField));
    await tester.pumpAndSettle();
    expect(find.text('holidays'), findsOneWidget);
    expect(queries.last, 'holidays');
    expect(tvClear(), findsOneWidget);
    expect(clearInField(), findsNothing, reason: 'out of reach of the remote inside the field');

    // The entry of the TV keyboard: the Focus around the field, whose own focus is excluded
    final entry = find.descendant(of: find.byType(SearchField), matching: find.byType(ExcludeFocus));
    Focus.of(tester.element(entry.first)).requestFocus();
    await tester.pumpAndSettle();
    expect(focusedIn(find.byType(SearchField)), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedIn(tvClear()), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('holidays'), findsNothing);
    expect(tvClear(), findsNothing);
  });

  testWidgets('a phone keeps Clear inside the field', (tester) async {
    await pumpAlbums(tester, tvMode: false);
    expect(clearInField(), findsNothing);

    await tester.enterText(find.byType(TextField), 'holidays');
    await tester.pumpAndSettle();
    expect(queries.last, 'holidays');
    expect(clearInField(), findsOneWidget);
    expect(tvClear(), findsNothing);

    await tester.tap(clearInField());
    await tester.pumpAndSettle();
    expect(find.text('holidays'), findsNothing);
    expect(clearInField(), findsNothing);
    verifyNever(() => tvApi.editText(any()));
  });
}
