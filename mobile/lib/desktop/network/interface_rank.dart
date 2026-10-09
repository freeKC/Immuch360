// The network interfaces of a computer, for discovery (the /24 scans, SSDP, Plex and Tapo probes) and for "Share this
// computer on the network". The phone rules rank interfaces by their Linux and BSD names (wlan0, eth0, en0); Windows
// gives friendly, translated names ("Wi-Fi", "Ethernet 2", "Connexion au réseau local* 4") and lists the virtual
// adapters of WSL, Hyper-V, VPN clients and Bluetooth next to the real ones, so the computers get their own ranking
// here, one function for both uses:
//
// - virtual switches, VPN and tunnel adapters, Bluetooth and loopback are left out, by name and, on Windows, by the
//   driver's description and the interface type, which a user cannot rename. A virtual switch that carries the
//   default route stays: with a Hyper-V external switch the LAN itself goes through "vEthernet (...)";
// - then the adapter of the default route (the route the computer actually uses, from the system), the adapters with
//   a gateway, the Wi-Fi and Ethernet ones, the rest; among equals 192.168/16 and 10/8 before 172.16/12, where Docker,
//   WSL and Hyper-V usually live, then the system's order;
// - an adapter chosen in the settings ("Network for discovery and sharing", network_choice.dart) is the only one
//   used while it has an address, whatever these rules say.
//
// The share also leaves out the addresses of networks Windows marks as public, unless the user said "Share for this
// session" for that network (computer_share.dart). It fails closed: on Windows, an address whose network category
// could not be read counts as public too (network_category.dart).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/network/network_category.dart';
import 'package:immich_mobile/desktop/network/network_choice.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopInterfaces');

/// One private IPv4 address of an interface, in the order the computer uses them
@immutable
class RankedAddress {
  const RankedAddress({required this.name, required this.address, required this.tier, this.facts});

  /// The interface, as NetworkInterface.list names it
  final String name;

  /// In dotted form
  final String address;

  /// 0 for the chosen adapter or the default route, then 1 a gateway, 2 Wi-Fi or Ethernet, 3 anything else
  final int tier;

  /// What the system told of the interface, null where it tells nothing
  final AdapterFacts? facts;

  /// The /24 subnet, "192.168.1"
  String get subnet => address.substring(0, address.lastIndexOf('.'));

  /// Whether Windows marks the network of this address as public, or could not tell its category
  bool get isPublic => switch (facts?.category) {
    NetworkCategory.public || NetworkCategory.unknown => true,
    NetworkCategory.private || NetworkCategory.domain || null => false,
  };

  /// What "Share for this session" remembers: the network when Windows gives its id, else the interface
  String get networkKey => facts?.networkId ?? 'interface:$name';

  @override
  String toString() => 'RankedAddress($name, $address, tier $tier)';
}

/// Never used without the user choosing them: tunnels and VPN clients (the share would be reachable from the VPN's
/// network, a scan would probe a company's network), Bluetooth, loopback, Apple's peer to peer links. Case folded,
/// anywhere in the name or the description.
const _neverUsed = [
  'tailscale', 'zerotier', 'openvpn', 'wireguard', 'vpn', 'anyconnect', 'globalprotect', 'pangp', 'fortinet', //
  'forticlient', 'nordlynx', 'ipsec', 'tap', 'tun', 'wg', 'ppp', 'bluetooth', 'loopback', 'awdl', 'llw',
];

/// Virtual switches of virtual machines and containers: left out unless the default route goes through them
const _virtualSwitches = [
  'vethernet', 'wsl', 'hyper-v', 'virtualbox', 'vmware', 'vmnet', 'docker', 'br-', 'virbr', 'veth', 'bridge', //
  'lxc', 'podman',
];

/// Wi-Fi and Ethernet by name on Windows, Linux and macOS: "Wi-Fi", "WLAN", wlp2s0, "Ethernet 2", enp3s0, eth0, en0
const _wifiOrEthernet = ['wi-fi', 'wifi', 'wlan', 'wl', 'ethernet', 'eth', 'en'];

bool _isPrivate(InternetAddress address) {
  final bytes = address.rawAddress;
  return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) || (bytes[0] == 192 && bytes[1] == 168);
}

/// The private IPv4 addresses among [addresses], loopback and link-local ones left out
Iterable<(int, String, InternetAddress)> _usable(List<(String, InternetAddress)> addresses) sync* {
  for (final (index, (name, address)) in addresses.indexed) {
    if (address.type == InternetAddressType.IPv4 &&
        !address.isLoopback &&
        !address.isLinkLocal &&
        _isPrivate(address)) {
      yield (index, name, address);
    }
  }
}

/// Why an interface may be left out
enum _Exclusion { none, unlessDefaultRoute, always }

_Exclusion _exclusionOf(String name, AdapterFacts? facts) {
  final kind = facts?.kind;
  if (kind == AdapterKind.tunnel || kind == AdapterKind.mobile || kind == AdapterKind.loopback) {
    return _Exclusion.always;
  }
  final texts = [name.toLowerCase(), (facts?.description ?? '').toLowerCase()];
  bool mentions(List<String> tokens) => tokens.any((token) => texts.any((text) => text.contains(token)));
  if (mentions(_neverUsed)) {
    return _Exclusion.always;
  }
  return mentions(_virtualSwitches) ? _Exclusion.unlessDefaultRoute : _Exclusion.none;
}

int _tierOf(String name, AdapterFacts? facts) {
  if (facts?.defaultRoute ?? false) {
    return 0;
  }
  if (facts?.hasGateway ?? false) {
    return 1;
  }
  final kind = facts?.kind;
  if (kind == AdapterKind.wifi || kind == AdapterKind.ethernet || _wifiOrEthernet.any(name.toLowerCase().startsWith)) {
    return 2;
  }
  return 3;
}

/// The order in which a computer uses the private IPv4 [addresses] of its interfaces (interface name, address), with
/// what the system tells of them in [facts] (by interface name, see desktopAdapterFacts) and the adapter the user
/// [chosen] in the settings; see the top of this file. Left out addresses are not in the answer. With
/// [categoriesExpected] (Windows, which tells the category of every network), an interface the system told nothing of
/// is on a network of unknown category: the reading failed, or the adapter came after it.
List<RankedAddress> rankDesktopAddresses(
  List<(String, InternetAddress)> addresses, {
  Map<String, AdapterFacts> facts = const {},
  String? chosen,
  bool categoriesExpected = false,
}) {
  AdapterFacts? factsOf(String name) =>
      facts[name] ?? (categoriesExpected ? AdapterFacts(name: name, category: NetworkCategory.unknown) : null);

  final usable = _usable(addresses).toList();
  final choice = chosen?.toLowerCase();
  if (choice != null) {
    final picked = [
      for (final (_, name, address) in usable)
        if (name.toLowerCase() == choice)
          RankedAddress(name: name, address: address.address, tier: 0, facts: factsOf(name)),
    ];
    if (picked.isNotEmpty) {
      return picked;
    }
  }

  final ranked = <(int, int, int, RankedAddress)>[];
  for (final (index, name, address) in usable) {
    final adapter = factsOf(name);
    if (adapter != null && !adapter.isUp) {
      continue;
    }
    final excluded = switch (_exclusionOf(name, adapter)) {
      _Exclusion.none => false,
      _Exclusion.unlessDefaultRoute => !(adapter?.defaultRoute ?? false),
      _Exclusion.always => true,
    };
    if (excluded) {
      continue;
    }
    final tier = _tierOf(name, adapter);
    final range = address.rawAddress[0] == 172 ? 1 : 0;
    ranked.add((tier, range, index, RankedAddress(name: name, address: address.address, tier: tier, facts: adapter)));
  }
  ranked.sort((a, b) {
    if (a.$1 != b.$1) {
      return a.$1.compareTo(b.$1);
    }
    return a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$3.compareTo(b.$3);
  });
  return [for (final (_, _, _, address) in ranked) address];
}

/// What localIPv4Addresses answers on a computer: the addresses worth a scan, one per /24 subnet, two subnets at most,
/// in the order of [rankDesktopAddresses]
List<String> desktopLanAddressesOf(
  List<(String, InternetAddress)> addresses, {
  Map<String, AdapterFacts> facts = const {},
  String? chosen,
}) {
  final picked = <String>[];
  final subnets = <String>{};
  for (final candidate in rankDesktopAddresses(addresses, facts: facts, chosen: chosen)) {
    if (subnets.add(candidate.subnet)) {
      picked.add(candidate.address);
      if (picked.length == 2) {
        break;
      }
    }
  }
  return picked;
}

/// What phoneShareAddressesOf answers on a computer: every address other devices of the local network may reach it
/// at, in the order of [rankDesktopAddresses], before the public network rule ([servedShareAddresses])
List<String> desktopShareAddressesOf(
  List<(String, InternetAddress)> addresses, {
  Map<String, AdapterFacts> facts = const {},
  String? chosen,
}) => [
  ...{for (final candidate in rankDesktopAddresses(addresses, facts: facts, chosen: chosen)) candidate.address},
];

/// Every interface with a private IPv4 address, for the choice of the settings: the ones the automatic choice uses
/// first, in its order, then the ones it leaves out (a virtual switch the LAN goes through, a VPN the user wants)
List<(String, String)> desktopAdapterChoicesOf(
  List<(String, InternetAddress)> addresses, {
  Map<String, AdapterFacts> facts = const {},
}) {
  final choices = <String, String>{};
  for (final candidate in rankDesktopAddresses(addresses, facts: facts)) {
    choices.putIfAbsent(candidate.name, () => candidate.address);
  }
  for (final (_, name, address) in _usable(addresses)) {
    choices.putIfAbsent(name, () => address.address);
  }
  return [for (final MapEntry(:key, :value) in choices.entries) (key, value)];
}

/// The public networks the user shares on anyway, by [RankedAddress.networkKey], until the app quits
final _publicNetworksAllowed = <String>{};

/// Whether [address] is on a network Windows marks as public that the user did not allow for this session
bool isLeftOutAsPublic(RankedAddress address) =>
    address.isPublic && !_publicNetworksAllowed.contains(address.networkKey);

/// "Share for this session": the networks of [addresses] are shared on until the app quits, even marked as public
void allowPublicNetworksForSession(Iterable<RankedAddress> addresses) =>
    _publicNetworksAllowed.addAll(addresses.map((address) => address.networkKey));

@visibleForTesting
void forgetPublicNetworksAllowed() => _publicNetworksAllowed.clear();

/// The addresses the share listens on and shows, among the [candidates] of [rankDesktopAddresses]: the ones of a public
/// network the user did not allow are left out
List<String> servedShareAddresses(List<RankedAddress> candidates) => [
  ...{
    for (final candidate in candidates)
      if (!isLeftOutAsPublic(candidate)) candidate.address,
  },
];

/// The IPv4 addresses of every interface of this computer, by interface name
Future<List<(String, InternetAddress)>> _interfaceAddresses() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  return [
    for (final interface in interfaces)
      for (final address in interface.addresses) (interface.name, address),
  ];
}

/// What localIPv4Addresses answers on a computer, from the IPv4 [addresses] it listed: [desktopLanAddressesOf] with
/// what the system tells of the adapters and the user's choice
Future<List<String>> desktopLanAddressesFrom(List<(String, InternetAddress)> addresses) async {
  final facts = await desktopAdapterFacts();
  final chosen = await DesktopNetworkChoice.load();
  return desktopLanAddressesOf(addresses, facts: facts, chosen: chosen);
}

/// The addresses the share of this computer could use, in their order, before the public network rule
Future<List<RankedAddress>> desktopShareCandidates() async {
  final addresses = await _interfaceAddresses();
  final facts = await desktopAdapterFacts();
  final chosen = await DesktopNetworkChoice.load();
  // The system this runs on, as desktopAdapterFacts reads it
  return rankDesktopAddresses(addresses, facts: facts, chosen: chosen, categoriesExpected: Platform.isWindows);
}

/// Every interface of this computer with a private IPv4 address, for the choice of the settings
Future<List<(String, String)>> desktopAdapterChoices() async {
  try {
    return desktopAdapterChoicesOf(await _interfaceAddresses(), facts: await desktopAdapterFacts());
  } catch (error) {
    _log.fine('No network interface: $error');
    return const [];
  }
}

/// The addresses other devices of the local network reach this computer at, what phoneShareLocalAddresses answers on
/// a computer: the share listens on these (and on loopback) and shows them
Future<List<String>> desktopShareLocalAddresses() async {
  try {
    return servedShareAddresses(await desktopShareCandidates());
  } catch (error) {
    _log.fine('No network interface: $error');
    return const [];
  }
}

/// The name this computer announces when it is shared on the network: its host name, as the phones announce theirs
Future<String> desktopShareDeviceName() async {
  try {
    final name = Platform.localHostname.trim();
    return name.isNotEmpty ? name : 'computer';
  } catch (error) {
    _log.fine('No host name: $error');
    return 'computer';
  }
}
