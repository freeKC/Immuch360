// The toasts of a big screen need a context under the navigator's overlay: the navigator's own context is above it,
// where a toast finds no overlay (found on the TV emulator on 25 November 2026)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/screen_player_prompts.dart';

void main() {
  testWidgets('a context under the overlay of the navigator, none before it is built', (tester) async {
    final key = GlobalKey<NavigatorState>();
    expect(overlayChildContext(key), isNull);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        home: const Scaffold(body: Text('home')),
      ),
    );
    expect(Overlay.maybeOf(key.currentContext!), isNull, reason: 'the navigator is above its overlay');
    final context = overlayChildContext(key);
    expect(context, isNotNull);
    expect(Overlay.maybeOf(context!), isNotNull);
    expect(Navigator.maybeOf(context), isNotNull);
  });
}
