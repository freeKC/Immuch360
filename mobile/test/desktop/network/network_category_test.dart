import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/desktop/network/network_category.dart';

void main() {
  group('Linux routing table', () {
    // /proc/net/route of a laptop on Ethernet and Wi-Fi with Docker: little endian hexadecimal addresses
    const table =
        'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n'
        'wlp2s0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n'
        'enp3s0\t00000000\t010AA8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'
        'enp3s0\t000AA8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0\n'
        'docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n'
        'wg0\t0000060A\t0100060A\t0002\t0\t0\t0\t00FFFFFF\t0\t0\t0\n';

    test('the default route with the lowest metric, and every adapter with a gateway', () {
      final facts = linuxRouteFacts(table);
      expect(facts.keys, unorderedEquals(['wlp2s0', 'enp3s0']));
      expect(facts['enp3s0']!.defaultRoute, isTrue);
      expect(facts['wlp2s0']!.defaultRoute, isFalse);
      expect(facts['wlp2s0']!.hasGateway, isTrue);
    });

    test('an empty or odd table tells nothing', () {
      expect(linuxRouteFacts(''), isEmpty);
      expect(linuxRouteFacts('Iface\tDestination\n\nnonsense\n'), isEmpty);
    });
  });

  group('Windows values', () {
    test('interface types', () {
      expect(windowsAdapterKind(6), AdapterKind.ethernet);
      expect(windowsAdapterKind(71), AdapterKind.wifi);
      expect(windowsAdapterKind(24), AdapterKind.loopback);
      for (final tunnel in [131, 23, 53]) {
        expect(windowsAdapterKind(tunnel), AdapterKind.tunnel, reason: '$tunnel');
      }
      expect(windowsAdapterKind(243), AdapterKind.mobile);
      expect(windowsAdapterKind(244), AdapterKind.mobile);
      expect(windowsAdapterKind(1), AdapterKind.other);
    });

    test('network categories', () {
      expect(windowsNetworkCategory(0), NetworkCategory.public);
      expect(windowsNetworkCategory(1), NetworkCategory.private);
      expect(windowsNetworkCategory(2), NetworkCategory.domain);
      expect(windowsNetworkCategory(7), isNull);
    });

    test('GUIDs as COM lays them out and as the IP helper writes them', () {
      final bytes = guidBytes('{DCB00C01-570F-4A9B-8D69-199FDBA5723B}');
      expect(bytes, [0x01, 0x0C, 0xB0, 0xDC, 0x0F, 0x57, 0x9B, 0x4A, 0x8D, 0x69, 0x19, 0x9F, 0xDB, 0xA5, 0x72, 0x3B]);
      expect(guidString(bytes), '{DCB00C01-570F-4A9B-8D69-199FDBA5723B}');
      expect(guidString(guidBytes('dcb00000-570f-4a9b-8d69-199fdba5723b')), '{DCB00000-570F-4A9B-8D69-199FDBA5723B}');
      expect(() => guidBytes('{1234}'), throwsFormatException);
      expect(guidString(Uint8List(16)), '{00000000-0000-0000-0000-000000000000}');
    });
  });

  // What the IP helper and the Network List Manager answer on a real Windows (a PC through the wrapper, the Windows CI
  // runner). Nothing of the machine is printed: names and categories stay in the test.
  group('on a real Windows', () {
    setUp(forgetDesktopAdapterFacts);

    test('the adapters come with their kind, and the connected networks with a category', () async {
      final adapters = readWindowsAdapterFacts();
      expect(adapters, isNotEmpty);
      expect(adapters.every((adapter) => adapter.name.isNotEmpty), isTrue);
      expect(adapters.any((adapter) => adapter.kind == AdapterKind.loopback), isTrue);
      expect(adapters.where((adapter) => adapter.defaultRoute).length, lessThanOrEqualTo(1));
      final connected = adapters.where((adapter) => adapter.isUp && adapter.hasGateway);
      if (connected.isNotEmpty) {
        // A network with a router has a profile in Windows, hence a category and an id
        expect(connected.any((adapter) => adapter.category != null && adapter.networkId != null), isTrue);
      }
    }, skip: !Platform.isWindows);

    test('the same through an isolate, and the share ranks the real interfaces with them', () async {
      final facts = await desktopAdapterFacts();
      expect(facts, isNotEmpty);
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final addresses = [
        for (final interface in interfaces)
          for (final address in interface.addresses) (interface.name, address),
      ];
      // NetworkInterface.list names Windows interfaces by their friendly names, which the facts are keyed by
      expect(addresses.every((entry) => facts.containsKey(entry.$1)), isTrue);
      final ranked = rankDesktopAddresses(addresses, facts: facts);
      expect(ranked.every((candidate) => InternetAddress(candidate.address).type == InternetAddressType.IPv4), isTrue);
      expect(ranked.every((candidate) => candidate.facts?.kind != AdapterKind.tunnel), isTrue);
    }, skip: !Platform.isWindows);
  });
}
