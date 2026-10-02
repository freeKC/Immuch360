// The "Buffering…" indicator of the video page of a network share. The native player reports no buffering state:
// the indicator follows the position and the status of the page player, set here by hand.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_buffering.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';

import '../../pages/network/network_test_app.dart';

const _playerKey = 'network:nas:/holiday.mp4';
const _wakelockChannel = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

/// The page player, moved by the test as the native player would
class _ScriptedPlayer extends VideoPlayerNotifier {
  void set({Duration? position, VideoPlaybackStatus? status}) {
    state = state.copyWith(position: position ?? state.position, status: status ?? state.status);
  }
}

void main() {
  late _ScriptedPlayer player;
  late ValueNotifier<bool> loading;

  setUp(() {
    player = _ScriptedPlayer();
    loading = ValueNotifier(false);
    // The player lets the screen sleep again when it is disposed
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      _wakelockChannel,
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() {
    loading.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(_wakelockChannel, null);
  });

  Future<void> pumpIndicator(WidgetTester tester) => pumpNetworkTestApp(
    tester,
    home: ValueListenableBuilder<bool>(
      valueListenable: loading,
      builder: (context, isLoading, _) => NetworkVideoBufferingIndicator(playerKey: _playerKey, loading: isLoading),
    ),
    overrides: [videoPlayerProvider(_playerKey).overrideWith((ref) => player)],
  );

  final indicator = find.text('Buffering…');

  /// Plays on for [duration], the position moving every 100 ms
  Future<void> playOn(WidgetTester tester, Duration duration) async {
    for (var elapsed = Duration.zero; elapsed < duration; elapsed += const Duration(milliseconds: 100)) {
      player.set(position: player.state.position + const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pauses, so that no timer of the indicator outlives the test
  Future<void> pauseAtEnd(WidgetTester tester) async {
    player.set(status: VideoPlaybackStatus.paused);
    await tester.pump();
  }

  testWidgets('shows while the video loads, and hides once the native player is ready', (tester) async {
    await pumpIndicator(tester);
    expect(indicator, findsNothing);

    loading.value = true;
    await tester.pump();
    expect(indicator, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    loading.value = false;
    await tester.pump();
    expect(indicator, findsNothing);
  });

  testWidgets('shows when the position stands still for 700 ms while playing, hides when it moves again', (
    tester,
  ) async {
    await pumpIndicator(tester);
    player.set(status: VideoPlaybackStatus.playing);
    await tester.pump();

    await playOn(tester, const Duration(seconds: 2));
    expect(indicator, findsNothing, reason: 'the video plays smoothly');

    // The share stalls: the position stops
    await tester.pump(const Duration(milliseconds: 500));
    expect(indicator, findsNothing, reason: 'a short hiccup shows nothing');
    await tester.pump(const Duration(milliseconds: 300));
    expect(indicator, findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(indicator, findsOneWidget, reason: 'it stays as long as the stall lasts');

    player.set(position: player.state.position + const Duration(milliseconds: 40));
    await tester.pump();
    expect(indicator, findsNothing);

    await playOn(tester, const Duration(seconds: 1));
    expect(indicator, findsNothing);

    await pauseAtEnd(tester);
  });

  testWidgets('shows nothing for a paused or finished video, whose position stands still', (tester) async {
    await pumpIndicator(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(indicator, findsNothing);

    player.set(status: VideoPlaybackStatus.playing);
    await tester.pump(const Duration(seconds: 1));
    expect(indicator, findsOneWidget);

    // Paused during the stall: the indicator goes, and does not come back while paused
    player.set(status: VideoPlaybackStatus.paused);
    await tester.pump();
    expect(indicator, findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(indicator, findsNothing);

    player.set(status: VideoPlaybackStatus.completed);
    await tester.pump(const Duration(seconds: 2));
    expect(indicator, findsNothing);
  });

  testWidgets('shows while the page player reports buffering', (tester) async {
    await pumpIndicator(tester);
    player.set(status: VideoPlaybackStatus.buffering);
    await tester.pump();
    expect(indicator, findsOneWidget);

    // The position moves: the player plays again
    player.set(position: const Duration(milliseconds: 100), status: VideoPlaybackStatus.playing);
    await tester.pump();
    expect(indicator, findsNothing);

    await pauseAtEnd(tester);
  });
}
