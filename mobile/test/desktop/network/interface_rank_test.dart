import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/desktop/network/network_category.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';

/// The interfaces of a Windows 11 laptop in French as NetworkInterface.list names them, read with the Windows Dart SDK
/// (design 5.2): translated friendly names, the WSL switch, a VPN adapter, Wi-Fi Direct and Bluetooth adapters. Only
/// the names and the address classes were read there; the addresses are made up in the same classes.
final _windowsLaptop = <(String, InternetAddress)>[
  ('Connexion au réseau local', InternetAddress('169.254.12.34')),
  ('vEthernet (WSL (Hyper-V firewall))', InternetAddress('172.29.160.1')),
  ('Ethernet', InternetAddress('192.168.1.42')),
  ('Ethernet 3', InternetAddress('169.254.80.5')),
  ('OpenVPN Connect DCO Adapter', InternetAddress('169.254.33.7')),
  ('Connexion au réseau local* 4', InternetAddress('169.254.200.1')),
  ('Connexion au réseau local* 5', InternetAddress('169.254.201.1')),
  ('Connexion réseau Bluetooth', InternetAddress('169.254.99.9')),
  ('Wi-Fi', InternetAddress('192.168.50.17')),
  ('Loopback Pseudo-Interface 1', InternetAddress('127.0.0.1')),
];

const _wifi = AdapterFacts(
  name: 'Wi-Fi',
  description: 'Intel(R) Wi-Fi 6E AX211 160MHz',
  kind: AdapterKind.wifi,
  hasGateway: true,
  defaultRoute: true,
  category: NetworkCategory.private,
  networkId: '{11111111-2222-3333-4444-555555555555}',
);

const _ethernet = AdapterFacts(
  name: 'Ethernet',
  description: 'Realtek PCIe GbE Family Controller',
  kind: AdapterKind.ethernet,
);

const _wsl = AdapterFacts(
  name: 'vEthernet (WSL (Hyper-V firewall))',
  description: 'Hyper-V Virtual Ethernet Adapter',
  kind: AdapterKind.ethernet,
  // Windows puts the switch of WSL on an unidentified, public network
  category: NetworkCategory.public,
  networkId: '{99999999-0000-0000-0000-000000000001}',
);

List<String> _addressesOf(List<RankedAddress> ranked) => [for (final candidate in ranked) candidate.address];

void main() {
  tearDown(forgetPublicNetworksAllowed);

  group('on a Windows laptop, from the names alone', () {
    test('discovery scans the Ethernet and the Wi-Fi subnets, never the WSL one', () {
      expect(desktopLanAddressesOf(_windowsLaptop), ['192.168.1.42', '192.168.50.17']);
    });

    test('the phone rules would scan the WSL subnet and miss the Wi-Fi: the reason for these rules', () {
      expect(SubnetScanProbe.lanAddressesOf(_windowsLaptop), ['192.168.1.42', '172.29.160.1']);
    });

    test('the share shows the Ethernet and the Wi-Fi addresses only', () {
      expect(desktopShareAddressesOf(_windowsLaptop), ['192.168.1.42', '192.168.50.17']);
    });

    test('loopback, link-local, public and IPv6 addresses are never used', () {
      final ranked = rankDesktopAddresses([
        ('Wi-Fi', InternetAddress('203.0.113.9')),
        ('Wi-Fi', InternetAddress('fe80::1')),
        ('Wi-Fi', InternetAddress('fd00::5')),
        ('Ethernet', InternetAddress('100.64.3.2')),
        ('Ethernet', InternetAddress('169.254.1.1')),
        ('Loopback Pseudo-Interface 1', InternetAddress('127.0.0.1')),
      ]);
      expect(ranked, isEmpty);
    });
  });

  group('on Windows, with what the system tells', () {
    test('the adapter of the default route comes first, a gateway next, then Wi-Fi and Ethernet', () {
      final ranked = rankDesktopAddresses(
        [
          ('Ethernet', InternetAddress('192.168.1.42')),
          ('Connexion au réseau local* 4', InternetAddress('192.168.137.1')),
          ('Ethernet 2', InternetAddress('10.0.0.8')),
          ('Wi-Fi', InternetAddress('192.168.50.17')),
        ],
        facts: {
          'Ethernet': _ethernet,
          // The mobile hotspot of Windows: its own Wi-Fi Direct adapter, no gateway
          'Connexion au réseau local* 4': const AdapterFacts(
            name: 'Connexion au réseau local* 4',
            description: 'Microsoft Wi-Fi Direct Virtual Adapter #2',
            kind: AdapterKind.wifi,
          ),
          'Ethernet 2': const AdapterFacts(name: 'Ethernet 2', kind: AdapterKind.ethernet, hasGateway: true),
          'Wi-Fi': _wifi,
        },
      );
      expect(_addressesOf(ranked), ['192.168.50.17', '10.0.0.8', '192.168.1.42', '192.168.137.1']);
      expect([for (final candidate in ranked) candidate.tier], [0, 1, 2, 2]);
    });

    test('the WSL switch stays out whatever its kind, and its public network does not matter', () {
      final ranked = rankDesktopAddresses(
        _windowsLaptop,
        facts: {'Wi-Fi': _wifi, 'Ethernet': _ethernet, _wsl.name: _wsl},
      );
      expect(_addressesOf(ranked), ['192.168.50.17', '192.168.1.42']);
      expect(servedShareAddresses(ranked), ['192.168.50.17', '192.168.1.42']);
    });

    test('a Hyper-V external switch that carries the default route is the LAN: it stays', () {
      final ranked = rankDesktopAddresses(
        [
          ('vEthernet (WSL (Hyper-V firewall))', InternetAddress('172.29.160.1')),
          ('vEthernet (External Switch)', InternetAddress('192.168.1.42')),
        ],
        facts: {
          _wsl.name: _wsl,
          'vEthernet (External Switch)': const AdapterFacts(
            name: 'vEthernet (External Switch)',
            description: 'Hyper-V Virtual Ethernet Adapter #2',
            kind: AdapterKind.ethernet,
            hasGateway: true,
            defaultRoute: true,
          ),
        },
      );
      expect(_addressesOf(ranked), ['192.168.1.42']);
    });

    test('a VPN stays out even when the default route goes through it', () {
      final ranked = rankDesktopAddresses(
        [
          ('OpenVPN Connect DCO Adapter', InternetAddress('10.8.0.2')),
          ('Ethernet', InternetAddress('192.168.1.42')),
          ('Bureau', InternetAddress('10.9.0.2')),
          ('Ethernet 4', InternetAddress('10.10.0.2')),
        ],
        facts: {
          'OpenVPN Connect DCO Adapter': const AdapterFacts(
            name: 'OpenVPN Connect DCO Adapter',
            description: 'OpenVPN Data Channel Offload',
            kind: AdapterKind.tunnel,
            hasGateway: true,
            defaultRoute: true,
          ),
          'Ethernet': const AdapterFacts(name: 'Ethernet', kind: AdapterKind.ethernet, hasGateway: true),
          // Renamed by the user: the description still tells
          'Bureau': const AdapterFacts(
            name: 'Bureau',
            description: 'TAP-Windows Adapter V9',
            kind: AdapterKind.ethernet,
          ),
          'Ethernet 4': const AdapterFacts(
            name: 'Ethernet 4',
            description: 'Wintun Userspace Tunnel',
            kind: AdapterKind.ethernet,
          ),
        },
      );
      expect(_addressesOf(ranked), ['192.168.1.42']);
    });

    test('mobile broadband and adapters that are down stay out', () {
      final ranked = rankDesktopAddresses(
        [
          ('Cellulaire', InternetAddress('10.120.4.5')),
          ('Ethernet', InternetAddress('192.168.1.42')),
          ('Wi-Fi', InternetAddress('192.168.50.17')),
        ],
        facts: {
          'Cellulaire': const AdapterFacts(name: 'Cellulaire', kind: AdapterKind.mobile, hasGateway: true),
          'Ethernet': const AdapterFacts(name: 'Ethernet', kind: AdapterKind.ethernet, isUp: false),
          'Wi-Fi': _wifi,
        },
      );
      expect(_addressesOf(ranked), ['192.168.50.17']);
    });

    test('a Wi-Fi renamed by the user is still a Wi-Fi by its kind', () {
      final ranked = rankDesktopAddresses(
        [('Docker', InternetAddress('192.168.65.1')), ('Maison', InternetAddress('192.168.0.12'))],
        facts: {'Maison': const AdapterFacts(name: 'Maison', kind: AdapterKind.wifi)},
      );
      expect(_addressesOf(ranked), ['192.168.0.12']);
      expect(ranked.single.tier, 2);
    });
  });

  group('among equals', () {
    test('192.168/16 and 10/8 come before 172.16/12, then the system order', () {
      final ranked = rankDesktopAddresses([
        ('Ethernet 2', InternetAddress('172.20.1.5')),
        ('Ethernet 3', InternetAddress('10.1.2.3')),
        ('Ethernet', InternetAddress('192.168.1.42')),
      ]);
      expect(_addressesOf(ranked), ['10.1.2.3', '192.168.1.42', '172.20.1.5']);
    });

    test('discovery takes one address per subnet, two subnets at most; the share keeps every address', () {
      final addresses = [
        ('Ethernet', InternetAddress('192.168.1.42')),
        ('Wi-Fi', InternetAddress('192.168.1.43')),
        ('Ethernet 2', InternetAddress('10.0.0.8')),
        ('Ethernet 3', InternetAddress('10.0.1.8')),
      ];
      expect(desktopLanAddressesOf(addresses), ['192.168.1.42', '10.0.0.8']);
      expect(desktopShareAddressesOf(addresses), ['192.168.1.42', '192.168.1.43', '10.0.0.8', '10.0.1.8']);
    });
  });

  group('on macOS and Linux, by their interface names', () {
    test('macOS: en0 and a USB Ethernet, not the sharing bridge, VPN or peer to peer links', () {
      final addresses = [
        ('lo0', InternetAddress('127.0.0.1')),
        ('bridge100', InternetAddress('192.168.2.1')),
        ('utun3', InternetAddress('10.0.0.2')),
        ('awdl0', InternetAddress('169.254.4.4')),
        ('llw0', InternetAddress('169.254.4.5')),
        ('en0', InternetAddress('192.168.1.5')),
        ('en7', InternetAddress('192.168.8.20')),
      ];
      expect(desktopShareAddressesOf(addresses), ['192.168.1.5', '192.168.8.20']);
    });

    test('Linux: Wi-Fi and Ethernet, not Docker, libvirt, veth, WireGuard or Tailscale', () {
      final addresses = [
        ('lo', InternetAddress('127.0.0.1')),
        ('docker0', InternetAddress('172.17.0.1')),
        ('br-1a2b3c4d5e6f', InternetAddress('172.18.0.1')),
        ('virbr0', InternetAddress('192.168.122.1')),
        ('veth9f8e7d', InternetAddress('172.17.0.5')),
        ('wg0', InternetAddress('10.6.0.2')),
        ('tailscale0', InternetAddress('100.101.102.103')),
        ('wlp2s0', InternetAddress('192.168.1.77')),
        ('enp3s0', InternetAddress('192.168.10.4')),
      ];
      expect(desktopShareAddressesOf(addresses), ['192.168.1.77', '192.168.10.4']);
    });

    test('Linux: the default route of /proc/net/route ranks first', () {
      final addresses = [('wlp2s0', InternetAddress('192.168.1.77')), ('enp3s0', InternetAddress('192.168.10.4'))];
      final facts = linuxRouteFacts(
        'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n'
        'enp3s0\t00000000\t010AA8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0\n'
        'wlp2s0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0\n',
      );
      expect(desktopLanAddressesOf(addresses, facts: facts), ['192.168.10.4', '192.168.1.77']);
    });
  });

  group('the adapter chosen in the settings', () {
    test('is the only one used while it has an address, whatever its name and case', () {
      expect(desktopShareAddressesOf(_windowsLaptop, chosen: 'wi-fi'), ['192.168.50.17']);
      expect(desktopLanAddressesOf(_windowsLaptop, chosen: 'WI-FI'), ['192.168.50.17']);
    });

    test('may be one the automatic choice leaves out', () {
      expect(desktopShareAddressesOf(_windowsLaptop, chosen: 'vEthernet (WSL (Hyper-V firewall))'), ['172.29.160.1']);
    });

    test('is ignored while it has no usable address', () {
      expect(desktopShareAddressesOf(_windowsLaptop, chosen: 'Wi-Fi 2'), ['192.168.1.42', '192.168.50.17']);
      expect(desktopShareAddressesOf(_windowsLaptop, chosen: 'Ethernet 3'), ['192.168.1.42', '192.168.50.17']);
    });

    test('is offered among every interface with a private address, the automatic order first', () {
      expect(desktopAdapterChoicesOf(_windowsLaptop), [
        ('Ethernet', '192.168.1.42'),
        ('Wi-Fi', '192.168.50.17'),
        ('vEthernet (WSL (Hyper-V firewall))', '172.29.160.1'),
      ]);
    });
  });

  group('the public network rule of the share', () {
    final cafe = <(String, InternetAddress)>[('Wi-Fi', InternetAddress('10.42.0.15'))];
    const cafeWifi = AdapterFacts(
      name: 'Wi-Fi',
      kind: AdapterKind.wifi,
      hasGateway: true,
      defaultRoute: true,
      category: NetworkCategory.public,
      networkId: '{AAAAAAAA-0000-0000-0000-000000000001}',
    );

    test('an address on a network marked public is left out, a private or domain one is served', () {
      final ranked = rankDesktopAddresses(
        [...cafe, ('Ethernet', InternetAddress('192.168.1.42')), ('Ethernet 2', InternetAddress('10.1.0.3'))],
        facts: {
          'Wi-Fi': cafeWifi,
          'Ethernet': const AdapterFacts(
            name: 'Ethernet',
            kind: AdapterKind.ethernet,
            category: NetworkCategory.private,
          ),
          'Ethernet 2': const AdapterFacts(
            name: 'Ethernet 2',
            kind: AdapterKind.ethernet,
            category: NetworkCategory.domain,
          ),
        },
      );
      expect(ranked.first.isPublic, isTrue);
      expect(isLeftOutAsPublic(ranked.first), isTrue);
      expect(servedShareAddresses(ranked), ['192.168.1.42', '10.1.0.3']);
    });

    test('"Share for this session" serves that network, and that network only', () {
      final ranked = rankDesktopAddresses(cafe, facts: {'Wi-Fi': cafeWifi});
      expect(servedShareAddresses(ranked), isEmpty);

      allowPublicNetworksForSession(ranked);
      expect(servedShareAddresses(ranked), ['10.42.0.15']);

      // The next café: another network for Windows, through the same adapter
      final next = rankDesktopAddresses(
        [('Wi-Fi', InternetAddress('10.42.7.3'))],
        facts: {
          'Wi-Fi': const AdapterFacts(
            name: 'Wi-Fi',
            kind: AdapterKind.wifi,
            defaultRoute: true,
            category: NetworkCategory.public,
            networkId: '{AAAAAAAA-0000-0000-0000-000000000002}',
          ),
        },
      );
      expect(servedShareAddresses(next), isEmpty);
    });

    test('without a category (macOS, Linux, an adapter Windows has no network for), the address is served', () {
      expect(servedShareAddresses(rankDesktopAddresses(cafe)), ['10.42.0.15']);
    });

    test('the adapter chosen in the settings follows the rule too', () {
      final ranked = rankDesktopAddresses(cafe, facts: {'Wi-Fi': cafeWifi}, chosen: 'Wi-Fi');
      expect(servedShareAddresses(ranked), isEmpty);
    });

    test('on Windows, a network whose category could not be read is left out until the user shares on it', () {
      // The Network List Manager could not be read, or did not list the network of this adapter
      final unknown = rankDesktopAddresses(
        cafe,
        facts: {
          'Wi-Fi': const AdapterFacts(
            name: 'Wi-Fi',
            kind: AdapterKind.wifi,
            hasGateway: true,
            defaultRoute: true,
            category: NetworkCategory.unknown,
          ),
        },
      );
      expect(unknown.single.isPublic, isTrue);
      expect(servedShareAddresses(unknown), isEmpty);
      allowPublicNetworksForSession(unknown);
      expect(servedShareAddresses(unknown), ['10.42.0.15']);
    });

    test('on Windows, an interface the system told nothing of counts as on a network of unknown category', () {
      // The whole reading failed: no facts at all, which elsewhere means a system without categories
      final unread = rankDesktopAddresses(cafe, categoriesExpected: true);
      expect(unread.single.facts?.category, NetworkCategory.unknown);
      expect(servedShareAddresses(unread), isEmpty);
      expect(servedShareAddresses(rankDesktopAddresses(cafe, chosen: 'Wi-Fi', categoriesExpected: true)), isEmpty);
      // A known category still decides
      expect(servedShareAddresses(rankDesktopAddresses(cafe, facts: {'Wi-Fi': _wifi}, categoriesExpected: true)), [
        '10.42.0.15',
      ]);
    });
  });
}
