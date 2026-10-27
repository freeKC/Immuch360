// The gate of the AI relief on the Meta Quest (design-final 2026-10-26, section 3.5): the Quest 3 and 3S offered, the
// Quest 2 and Pro greyed unless the untested switch is on, a device under 6 GB refused, the APK of the phone flavour
// greyed, and nothing at all off Horizon OS or with the AI features off.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/ai_immersive_config.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

void main() {
  // The memory Android sees on a Quest 3: 8 GB physical, part of it kept by the kernel
  const quest3 = ReliefDeviceFacts(device: 'eureka', memoryMiB: 7600);

  ReliefGate gate({
    bool horizonOs = true,
    bool enabled = true,
    bool olderHeadsets = false,
    String? flavor = 'quest',
    ReliefDeviceFacts? facts = quest3,
  }) =>
      reliefGateOf(horizonOs: horizonOs, enabled: enabled, olderHeadsets: olderHeadsets, flavor: flavor, facts: facts);

  group('reliefGateOf', () {
    test('offers the relief on a Quest 3 and a Quest 3S', () {
      expect(gate(), ReliefGate.offered);
      expect(gate(facts: const ReliefDeviceFacts(device: 'panther', memoryMiB: 7600)), ReliefGate.offered);
    });

    test('greys it on a Quest 2 and a Quest Pro, said not tested, until the untested switch is on', () {
      const quest2 = ReliefDeviceFacts(device: 'hollywood', memoryMiB: 5600);
      const questPro = ReliefDeviceFacts(device: 'seacliff', memoryMiB: 11600);

      expect(gate(facts: quest2), const ReliefGate.refused(ReliefRefusal.headset));
      expect(gate(facts: questPro), const ReliefGate.refused(ReliefRefusal.headset));
      // On: offered, with a passing warning that it may take several seconds
      expect(gate(facts: quest2, olderHeadsets: true), ReliefGate.offeredSlow);
      expect(gate(facts: questPro, olderHeadsets: true), ReliefGate.offeredSlow);
      // The switch changes nothing on a Quest 3
      expect(gate(olderHeadsets: true), ReliefGate.offered);
    });

    test('refuses a device that sees 4.5 GiB, whatever its name and the switch', () {
      for (final device in ['eureka', 'hollywood', 'other']) {
        expect(
          gate(facts: ReliefDeviceFacts(device: device, memoryMiB: 4608), olderHeadsets: true),
          const ReliefGate.refused(ReliefRefusal.memory),
          reason: device,
        );
      }
      // 5 GiB seen, 6 GB physical: enough
      expect(gate(facts: const ReliefDeviceFacts(device: 'eureka', memoryMiB: 5120)), ReliefGate.offered);
    });

    test('offers it on another Horizon OS device of 6 GB or more', () {
      expect(gate(facts: const ReliefDeviceFacts(device: 'a-new-headset', memoryMiB: 11000)), ReliefGate.offered);
    });

    test('greys it in the APK of the phone flavour, whatever the headset', () {
      expect(gate(flavor: 'phone'), const ReliefGate.refused(ReliefRefusal.build));
      expect(gate(flavor: null), const ReliefGate.refused(ReliefRefusal.build));
      expect(
        gate(
          flavor: 'phone',
          facts: const ReliefDeviceFacts(device: 'eureka', memoryMiB: 4000),
        ),
        const ReliefGate.refused(ReliefRefusal.build),
      );
    });

    test('offers it when the device could not be read: the immersive viewer checks again', () {
      expect(gate(facts: null), ReliefGate.offered);
    });

    test('shows nothing off Horizon OS, nor with the AI features off', () {
      expect(gate(horizonOs: false), ReliefGate.hidden);
      expect(gate(enabled: false), ReliefGate.hidden);
      expect(gate(enabled: false, flavor: 'phone'), ReliefGate.hidden);
      expect(ReliefGate.hidden.visible, isFalse);
      expect(const ReliefGate.refused(ReliefRefusal.build).visible, isTrue);
      expect(const ReliefGate.refused(ReliefRefusal.build).isOffered, isFalse);
      expect(ReliefGate.offeredSlow.isOffered, isTrue);
    });
  });

  group('reliefGateProvider', () {
    late List<String> factsRead;

    ProviderContainer container({
      bool horizonOs = true,
      AiImmersiveConfig config = const AiImmersiveConfig(),
      String? flavor = 'quest',
      Future<ReliefDeviceFacts?> Function()? facts,
    }) {
      final container = ProviderContainer(
        overrides: [
          isHorizonOsProvider.overrideWith((ref) async => horizonOs),
          appConfigProvider.overrideWithValue(AppConfig(aiImmersive: config)),
          appFlavorProvider.overrideWithValue(flavor),
          reliefDeviceFactsProvider.overrideWith((ref) {
            factsRead.add('read');
            return (facts ?? () async => quest3)();
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// The gate once the platform and the device answered
    Future<ReliefGate> settled(ProviderContainer container) async {
      final subscription = container.listen(reliefGateProvider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(isHorizonOsProvider.future);
      // The device is read by the gate itself, when it needs it
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      return container.read(reliefGateProvider);
    }

    setUp(() => factsRead = []);

    test('reads the device and offers the relief on a Quest 3 of the quest flavour', () async {
      expect(await settled(container()), ReliefGate.offered);
      expect(factsRead, ['read']);
    });

    test('follows the untested switch for a Quest 2', () async {
      Future<ReliefDeviceFacts?> quest2() async => const ReliefDeviceFacts(device: 'hollywood', memoryMiB: 5600);

      expect(await settled(container(facts: quest2)), const ReliefGate.refused(ReliefRefusal.headset));
      expect(
        await settled(container(facts: quest2, config: const AiImmersiveConfig(olderHeadsets: true))),
        ReliefGate.offeredSlow,
      );
    });

    test('greys the phone flavour without reading the device', () async {
      expect(await settled(container(flavor: 'phone')), const ReliefGate.refused(ReliefRefusal.build));
      expect(factsRead, isEmpty);
    });

    test('shows nothing on a phone, nor with the AI features off, without reading the device', () async {
      expect(await settled(container(horizonOs: false)), ReliefGate.hidden);
      expect(await settled(container(config: const AiImmersiveConfig(enabled: false))), ReliefGate.hidden);
      expect(factsRead, isEmpty);
    });

    test('shows nothing while the device is read, and offers it when the read fails', () async {
      final read = Completer<ReliefDeviceFacts?>();
      final waiting = container(facts: () => read.future);
      final subscription = waiting.listen(reliefGateProvider, (_, _) {});
      addTearDown(subscription.close);
      await waiting.read(isHorizonOsProvider.future);

      expect(waiting.read(reliefGateProvider), ReliefGate.hidden);
      read.complete(const ReliefDeviceFacts(device: 'eureka', memoryMiB: 4608));
      await Future<void>.delayed(Duration.zero);
      expect(waiting.read(reliefGateProvider), const ReliefGate.refused(ReliefRefusal.memory));

      expect(
        await settled(container(facts: () async => throw StateError('no device information'))),
        ReliefGate.offered,
      );
    });
  });
}
