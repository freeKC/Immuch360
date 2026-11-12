// "Play from a phone" on a big screen: its list of phones ends above a navigation bar at the bottom of the screen

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/presentation/pages/play_on_screen/play_from_phone.page.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/screen_player.provider.dart';

import '../../../test_utils.dart';
import '../../system_navigation_bar.dart';
import '../../widgets/play_on_screen/play_on_test_app.dart';

/// The phones linked, without the secure storage
class _Phones extends LinkedPeersNotifier {
  _Phones(this.phones) : super(playLinkPhonesKey, maxLinkedPhones);

  final List<LinkedPeer> phones;

  @override
  Future<List<LinkedPeer>> build() async => phones;
}

/// A receiver that does not listen, without a network
class _Player extends ScreenPlayerController {
  @override
  ScreenPlayerView build() => const ScreenPlayerView();
}

void main() {
  setUpAll(TestUtils.init);

  testWidgets('ends its list above a navigation bar at the bottom of the screen', (tester) async {
    screenWithNavigationBar(tester);
    await pumpPlayOn(
      tester,
      const PlayFromPhonePage(),
      overrides: [
        playFromPhoneEnabledProvider.overrideWith((ref) => true),
        playFromPhoneAskProvider.overrideWith((ref) => false),
        isHorizonOsProvider.overrideWith((ref) async => false),
        screenPlayerProvider.overrideWith(_Player.new),
        linkedPhonesProvider.overrideWith(
          () => _Phones([
            for (var i = 1; i <= maxLinkedPhones; i++)
              LinkedPeer(id: 'phone-$i', name: 'Phone $i', key: Uint8List(32), linkedAt: DateTime.utc(2026, 11, i)),
          ]),
        ),
      ],
    );
    expect(find.text('Phone 1'), findsOneWidget);
    await scrollToEnd(tester, find.byType(Scrollable).first);
    expectAboveNavigationBar(
      tester,
      find.text(
        "A phone plays a film here with this screen's own access to the server: no password nor token comes with it. "
        'Removing a phone here, or this screen on the phone, ends the link.',
      ),
    );
  });
}
