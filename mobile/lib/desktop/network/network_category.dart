// What the operating system tells of the network adapters of a computer beyond their names, for the interface ranking
// (interface_rank.dart) and the public network rule of "Share this computer on the network" (computer_share.dart).
//
// Windows gives friendly, translated names ("Wi-Fi", "Connexion au réseau local* 4", "vEthernet (WSL)"), so names
// alone guess badly there. Its IP helper tells the kind of each adapter, whether it has a gateway and which one
// carries the default route, the route the computer actually uses; its Network List Manager tells the category the
// user gave each network (public, private, or a domain). Both are read through dart:ffi, with no plugin, in a short
// lived isolate so that the COM apartment of the window's thread is left alone. Linux tells the default route in
// /proc/net/route. macOS gives nothing here yet: names only.
//
// The category is a security signal only: Microsoft warns that it "must never be used to assume which Windows
// Firewall ports are open" (NLM_NETWORK_CATEGORY), and it is not used that way. Since the share relies on it to stay
// off a café's Wi-Fi, a category Windows could not tell is never taken as private: it is unknown, which the share
// treats as public (a disabled Network List Service, a failed COM call, an adapter read between two networks).

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _log = Logger('DesktopNetworkFacts');

/// The category Windows gives a network (NLM_NETWORK_CATEGORY)
enum NetworkCategory {
  /// A café, a hotel, an airport: the user does not trust the other devices
  public,
  private,

  /// The network of the user's company, authenticated by its domain controller
  domain,

  /// Windows was asked and could not tell: the Network List Manager could not be read, or it did not list the network
  /// of an adapter that has a gateway. The share treats it as public.
  unknown,
}

/// What an adapter is, from its interface type (Windows) or nothing (elsewhere)
enum AdapterKind { other, wifi, ethernet, tunnel, mobile, loopback }

/// What the system tells of one network adapter, keyed by the name NetworkInterface.list gives it (the friendly name on
/// Windows, the interface name elsewhere)
@immutable
class AdapterFacts {
  const AdapterFacts({
    required this.name,
    this.description = '',
    this.kind = AdapterKind.other,
    this.isUp = true,
    this.hasGateway = false,
    this.defaultRoute = false,
    this.category,
    this.networkId,
  });

  final String name;

  /// The driver's description on Windows ("Hyper-V Virtual Ethernet Adapter"), which a user cannot rename
  final String description;
  final AdapterKind kind;
  final bool isUp;
  final bool hasGateway;

  /// Whether the default route goes through this adapter: the one the computer reaches its servers through
  final bool defaultRoute;

  /// The category of its network, null when Windows has none for it (an adapter without a network, another system)
  final NetworkCategory? category;

  /// The id Windows gives its network, which stays the same when the computer comes back to it
  final String? networkId;

  @override
  String toString() =>
      'AdapterFacts(kind: ${kind.name}, up: $isUp, gateway: $hasGateway, default: $defaultRoute, '
      'category: ${category?.name})';
}

/// How long one reading of the system serves: the share asks every few seconds while it runs
const _factsTtl = Duration(seconds: 4);

Future<Map<String, AdapterFacts>>? _facts;
DateTime? _factsAt;

/// What the system tells of the adapters of this computer, by interface name; empty where it tells nothing or when the
/// reading fails, so that the ranking falls back to the names. Read again after a few seconds.
Future<Map<String, AdapterFacts>> desktopAdapterFacts() {
  final now = DateTime.now();
  final cached = _facts;
  final at = _factsAt;
  if (cached != null && at != null && now.difference(at) < _factsTtl) {
    return cached;
  }
  _factsAt = now;
  return _facts = _readFacts();
}

/// Forgets the last reading, so that the next one asks the system again
@visibleForTesting
void forgetDesktopAdapterFacts() {
  _facts = null;
  _factsAt = null;
}

Future<Map<String, AdapterFacts>> _readFacts() async {
  // The system this runs on, not the target platform a test may pretend to be: these read Windows and Linux APIs
  if (Platform.isWindows) {
    try {
      final (adapters, problems) = await Isolate.run(() {
        final problems = <String>[];
        return (readWindowsAdapterFacts(problems: problems), problems);
      });
      reportWindowsProblems(problems);
      return {for (final adapter in adapters) adapter.name: adapter};
    } catch (error) {
      // The share then counts every address as on a network of unknown category (interface_rank.dart)
      reportWindowsProblems(['the adapters could not be read: $error']);
      return const {};
    }
  }
  try {
    if (Platform.isLinux) {
      return linuxRouteFacts(await File('/proc/net/route').readAsString());
    }
  } catch (error) {
    _log.fine('The system tells nothing of the network adapters: $error');
  }
  return const {};
}

/// What the last reading of Windows could not read, so that a lasting failure is logged as a warning once rather than
/// at each reading, every few seconds while the share runs
var _lastProblems = '';

/// Logs what a reading of Windows could not read: a warning when it changed since the previous reading, since the
/// share then leaves the networks of unknown category out
@visibleForTesting
void reportWindowsProblems(List<String> problems) {
  final text = problems.join('; ');
  if (text != _lastProblems) {
    _lastProblems = text;
    if (text.isEmpty) {
      _log.info('The network categories of Windows can be read again');
    } else {
      _log.warning('Windows does not tell the network categories, the share treats them as public: $text');
    }
  } else if (text.isNotEmpty) {
    _log.fine('Network categories still unknown: $text');
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Linux

/// The adapters with a gateway in a Linux routing table ([procNetRoute], the text of /proc/net/route), the one of the
/// default route with the lowest metric marked as such
@visibleForTesting
Map<String, AdapterFacts> linuxRouteFacts(String procNetRoute) {
  const routeUp = 0x1;
  const routeGateway = 0x2;
  final gateways = <String>{};
  String? defaultRoute;
  int? defaultMetric;
  for (final line in procNetRoute.split('\n').skip(1)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 8) {
      continue;
    }
    final [name, destination, _, flagsText, _, _, metricText, mask, ...] = fields;
    final flags = int.tryParse(flagsText, radix: 16) ?? 0;
    if (flags & routeUp == 0 || flags & routeGateway == 0) {
      continue;
    }
    gateways.add(name);
    final metric = int.tryParse(metricText) ?? 0;
    if (destination == '00000000' && mask == '00000000' && (defaultMetric == null || metric < defaultMetric)) {
      defaultRoute = name;
      defaultMetric = metric;
    }
  }
  return {
    for (final name in gateways) name: AdapterFacts(name: name, hasGateway: true, defaultRoute: name == defaultRoute),
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Windows

/// The kind of a Windows adapter from its IANA interface type (IP_ADAPTER_ADDRESSES.IfType)
@visibleForTesting
AdapterKind windowsAdapterKind(int ifType) => switch (ifType) {
  6 => AdapterKind.ethernet,
  71 => AdapterKind.wifi,
  24 => AdapterKind.loopback,
  // IF_TYPE_TUNNEL, IF_TYPE_PPP, IF_TYPE_PROP_VIRTUAL: VPN clients (Wintun, OpenVPN) and dial-up links
  131 || 23 || 53 => AdapterKind.tunnel,
  // IF_TYPE_WWANPP, IF_TYPE_WWANPP2: mobile broadband, where the operator may hand out private addresses
  243 || 244 => AdapterKind.mobile,
  _ => AdapterKind.other,
};

/// NLM_NETWORK_CATEGORY to [NetworkCategory]
@visibleForTesting
NetworkCategory? windowsNetworkCategory(int value) => switch (value) {
  0 => NetworkCategory.public,
  1 => NetworkCategory.private,
  2 => NetworkCategory.domain,
  _ => null,
};

/// The registry form of a GUID, "{0A1B2C3D-...}", from its 16 bytes in memory (Data1, Data2 and Data3 little endian)
@visibleForTesting
String guidString(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String hex(int value, int digits) => value.toRadixString(16).padLeft(digits, '0').toUpperCase();
  final tail = [for (var i = 8; i < 16; i++) hex(bytes[i], 2)].join();
  return '{${hex(data.getUint32(0, Endian.little), 8)}-${hex(data.getUint16(4, Endian.little), 4)}-'
      '${hex(data.getUint16(6, Endian.little), 4)}-${tail.substring(0, 4)}-${tail.substring(4)}}';
}

/// The 16 bytes of the GUID [text] ("{...}" or without braces), as COM takes it
@visibleForTesting
Uint8List guidBytes(String text) {
  final hex = text.replaceAll(RegExp('[{}-]'), '');
  if (hex.length != 32) {
    throw FormatException('Not a GUID', text);
  }
  int part(int start, int length) => int.parse(hex.substring(start, start + length), radix: 16);
  final data = ByteData(16)
    ..setUint32(0, part(0, 8), Endian.little)
    ..setUint16(4, part(8, 4), Endian.little)
    ..setUint16(6, part(12, 4), Endian.little);
  for (var i = 0; i < 8; i++) {
    data.setUint8(8 + i, part(16 + i * 2, 2));
  }
  return data.buffer.asUint8List();
}

/// The adapters of this Windows computer with their kind, gateway, default route and network category. Synchronous
/// calls into iphlpapi and the Network List Manager: run it in an isolate of its own. What could not be read goes to
/// [problems], for the caller to log: the logger of an isolate run this way goes nowhere.
@visibleForTesting
List<AdapterFacts> readWindowsAdapterFacts({List<String>? problems}) {
  final categories = _readNetworkCategories(problems ?? []);
  final adapters = _readAdapters();
  if (adapters == null) {
    problems?.add('GetAdaptersAddresses failed');
    return const [];
  }
  return windowsAdapterFacts(adapters, categories);
}

/// The facts of the Windows [adapters], with the [categories] of the networks by adapter GUID that the Network List
/// Manager gave, null when it could not be read. A category it could not tell is unknown rather than missing for an
/// adapter with a gateway, the kind that reaches other people's devices: the share then treats it as public. Without a
/// gateway (a direct cable to a headset, a virtual switch), no category stays none, as Windows shows such networks.
@visibleForTesting
List<AdapterFacts> windowsAdapterFacts(
  List<WindowsAdapter> adapters,
  Map<String, (NetworkCategory, String)>? categories,
) => [
  for (final adapter in adapters)
    AdapterFacts(
      name: adapter.name,
      description: adapter.description,
      kind: windowsAdapterKind(adapter.ifType),
      isUp: adapter.isUp,
      hasGateway: adapter.hasGateway,
      defaultRoute: adapter.defaultRoute,
      category:
          categories?[adapter.guid]?.$1 ?? (categories == null || adapter.hasGateway ? NetworkCategory.unknown : null),
      networkId: categories?[adapter.guid]?.$2,
    ),
];

/// IP_ADAPTER_ADDRESSES_LH up to the gateways, the fields read here. The first two fields stand for the union of
/// Length and IfIndex with a 64 bit alignment, which the pointer after it keeps.
final class _AdapterAddresses extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int ifIndex;
  external Pointer<_AdapterAddresses> next;
  external Pointer<Utf8> adapterName;
  external Pointer<Void> firstUnicastAddress;
  external Pointer<Void> firstAnycastAddress;
  external Pointer<Void> firstMulticastAddress;
  external Pointer<Void> firstDnsServerAddress;
  external Pointer<Utf16> dnsSuffix;
  external Pointer<Utf16> description;
  external Pointer<Utf16> friendlyName;
  @Array(8)
  external Array<Uint8> physicalAddress;
  @Uint32()
  external int physicalAddressLength;
  @Uint32()
  external int flags;
  @Uint32()
  external int mtu;
  @Uint32()
  external int ifType;
  @Int32()
  external int operStatus;
  @Uint32()
  external int ipv6IfIndex;
  @Array(16)
  external Array<Uint32> zoneIndices;
  external Pointer<Void> firstPrefix;
  @Uint64()
  external int transmitLinkSpeed;
  @Uint64()
  external int receiveLinkSpeed;
  external Pointer<Void> firstWinsServerAddress;
  external Pointer<Void> firstGatewayAddress;
}

typedef _GetAdaptersAddressesNative =
    Uint32 Function(Uint32 family, Uint32 flags, Pointer<Void> reserved, Pointer<Void> addresses, Pointer<Uint32> size);
typedef _GetAdaptersAddresses =
    int Function(int family, int flags, Pointer<Void> reserved, Pointer<Void> addresses, Pointer<Uint32> size);
typedef _GetBestInterfaceNative = Uint32 Function(Uint32 destination, Pointer<Uint32> index);
typedef _GetBestInterface = int Function(int destination, Pointer<Uint32> index);

/// One adapter as the IP helper describes it; [guid] is its name there, "{...}" in upper case
@visibleForTesting
typedef WindowsAdapter = ({
  String name,
  String description,
  String guid,
  int ifType,
  bool isUp,
  bool hasGateway,
  bool defaultRoute,
});

/// Null when the IP helper could not list them
List<WindowsAdapter>? _readAdapters() {
  const afInet = 2;
  // GAA_FLAG_SKIP_ANYCAST, _SKIP_MULTICAST, _SKIP_DNS_SERVER, _INCLUDE_GATEWAYS
  const flags = 0x0002 | 0x0004 | 0x0008 | 0x0080;
  const errorBufferOverflow = 111;
  const ifOperStatusUp = 1;
  // 192.0.2.1 (documentation range) in network byte order: no route is that specific, so the answer is the adapter of
  // the default route. Nothing is sent.
  const anyRemoteAddress = 0x010200C0;

  final iphlpapi = DynamicLibrary.open('iphlpapi.dll');
  final getAdaptersAddresses = iphlpapi.lookupFunction<_GetAdaptersAddressesNative, _GetAdaptersAddresses>(
    'GetAdaptersAddresses',
  );
  final getBestInterface = iphlpapi.lookupFunction<_GetBestInterfaceNative, _GetBestInterface>('GetBestInterface');

  return using((arena) {
    final bestIndex = arena<Uint32>();
    // Fails without a default route (a network without a router): no adapter carries it then
    final best = getBestInterface(anyRemoteAddress, bestIndex) == 0 ? bestIndex.value : null;

    final size = arena<Uint32>()..value = 16 * 1024;
    for (var attempt = 0; attempt < 3; attempt++) {
      final buffer = malloc<Uint8>(size.value);
      try {
        final result = getAdaptersAddresses(afInet, flags, nullptr, buffer.cast(), size);
        if (result == errorBufferOverflow) {
          // An adapter came meanwhile: size now holds what is needed
          continue;
        }
        if (result != 0) {
          return null;
        }
        final adapters = <WindowsAdapter>[];
        for (var entry = buffer.cast<_AdapterAddresses>(); entry != nullptr; entry = entry.ref.next) {
          final adapter = entry.ref;
          adapters.add((
            name: adapter.friendlyName == nullptr ? '' : adapter.friendlyName.toDartString(),
            description: adapter.description == nullptr ? '' : adapter.description.toDartString(),
            guid: adapter.adapterName == nullptr ? '' : adapter.adapterName.toDartString().toUpperCase(),
            ifType: adapter.ifType,
            isUp: adapter.operStatus == ifOperStatusUp,
            hasGateway: adapter.firstGatewayAddress != nullptr,
            defaultRoute: best != null && adapter.ifIndex == best,
          ));
        }
        return adapters;
      } finally {
        malloc.free(buffer);
      }
    }
    return null;
  });
}

// The Network List Manager, through the vtables of its COM interfaces (netlistmgr.h). Every interface derives from
// IDispatch: IUnknown's three methods, then IDispatch's four, so each interface's own methods start at slot 7.
const _clsidNetworkListManager = '{DCB00C01-570F-4A9B-8D69-199FDBA5723B}';
const _iidNetworkListManager = '{DCB00000-570F-4A9B-8D69-199FDBA5723B}';
const _release = 2;
const _managerGetNetworkConnections = 9;
const _enumNext = 8;
const _connectionGetNetwork = 7;
const _connectionIsConnected = 9;
const _connectionGetAdapterId = 12;
const _networkGetNetworkId = 11;
const _networkGetCategory = 18;

typedef _CoInitializeExNative = Int32 Function(Pointer<Void> reserved, Uint32 model);
typedef _CoInitializeEx = int Function(Pointer<Void> reserved, int model);
typedef _CoUninitializeNative = Void Function();
typedef _CoUninitialize = void Function();
typedef _CoCreateInstanceNative =
    Int32 Function(
      Pointer<Uint8> clsid,
      Pointer<Void> outer,
      Uint32 context,
      Pointer<Uint8> iid,
      Pointer<Pointer<Void>> object,
    );
typedef _CoCreateInstance =
    int Function(
      Pointer<Uint8> clsid,
      Pointer<Void> outer,
      int context,
      Pointer<Uint8> iid,
      Pointer<Pointer<Void>> object,
    );

typedef _ReleaseNative = Uint32 Function(Pointer<Void> self);
typedef _ReleaseCall = int Function(Pointer<Void> self);
typedef _OutPointerNative = Int32 Function(Pointer<Void> self, Pointer<Pointer<Void>> out);
typedef _OutPointer = int Function(Pointer<Void> self, Pointer<Pointer<Void>> out);
typedef _OutInt32Native = Int32 Function(Pointer<Void> self, Pointer<Int32> out);
typedef _OutInt32 = int Function(Pointer<Void> self, Pointer<Int32> out);
typedef _OutInt16Native = Int32 Function(Pointer<Void> self, Pointer<Int16> out);
typedef _OutInt16 = int Function(Pointer<Void> self, Pointer<Int16> out);
typedef _OutGuidNative = Int32 Function(Pointer<Void> self, Pointer<Uint8> out);
typedef _OutGuid = int Function(Pointer<Void> self, Pointer<Uint8> out);
typedef _NextNative = Int32 Function(Pointer<Void> self, Uint32 count, Pointer<Pointer<Void>> out, Pointer<Uint32> got);
typedef _Next = int Function(Pointer<Void> self, int count, Pointer<Pointer<Void>> out, Pointer<Uint32> got);

/// The method in [slot] of the vtable of the COM object [self]
Pointer<NativeFunction<T>> _slot<T extends Function>(Pointer<Void> self, int slot) =>
    self.cast<Pointer<Pointer<Void>>>().value[slot].cast<NativeFunction<T>>();

void _releaseObject(Pointer<Void> self) {
  if (self != nullptr) {
    _slot<_ReleaseNative>(self, _release).asFunction<_ReleaseCall>()(self);
  }
}

/// The category and the network id of the network of each connected adapter, by adapter GUID ("{...}", upper case);
/// null when COM or the Network List Manager cannot be reached (the Network List Service disabled by a tool that
/// "debloats" Windows, for one), with the reason in [problems]
Map<String, (NetworkCategory, String)>? _readNetworkCategories(List<String> problems) {
  const coinitMultithreaded = 0;
  // RPC_E_CHANGED_MODE: the thread already has another apartment, which serves as well
  const changedMode = -2147417850;
  // CLSCTX_ALL
  const anyContext = 0x17;
  const variantTrue = -1;

  final ole32 = DynamicLibrary.open('ole32.dll');
  final coInitializeEx = ole32.lookupFunction<_CoInitializeExNative, _CoInitializeEx>('CoInitializeEx');
  final coUninitialize = ole32.lookupFunction<_CoUninitializeNative, _CoUninitialize>('CoUninitialize');
  final coCreateInstance = ole32.lookupFunction<_CoCreateInstanceNative, _CoCreateInstance>('CoCreateInstance');

  String hex(int hresult) => '0x${hresult.toUnsigned(32).toRadixString(16).toUpperCase()}';

  final initialized = coInitializeEx(nullptr, coinitMultithreaded);
  if (initialized < 0 && initialized != changedMode) {
    problems.add('CoInitializeEx ${hex(initialized)}');
    return null;
  }
  final categories = <String, (NetworkCategory, String)>{};
  try {
    return using((arena) {
      Pointer<Uint8> guid(String text) {
        final bytes = guidBytes(text);
        final pointer = arena<Uint8>(16);
        pointer.asTypedList(16).setAll(0, bytes);
        return pointer;
      }

      final out = arena<Pointer<Void>>();
      final created = coCreateInstance(
        guid(_clsidNetworkListManager),
        nullptr,
        anyContext,
        guid(_iidNetworkListManager),
        out,
      );
      if (created < 0) {
        problems.add('the Network List Manager is not there (${hex(created)})');
        return null;
      }
      final manager = out.value;
      try {
        final listed = _slot<_OutPointerNative>(manager, _managerGetNetworkConnections).asFunction<_OutPointer>()(
          manager,
          out,
        );
        if (listed < 0) {
          problems.add('GetNetworkConnections ${hex(listed)}');
          return null;
        }
        final connections = out.value;
        try {
          final next = _slot<_NextNative>(connections, _enumNext).asFunction<_Next>();
          final got = arena<Uint32>();
          final connected = arena<Int16>();
          final category = arena<Int32>();
          final guidOut = arena<Uint8>(16);
          // S_OK with one connection each time; S_FALSE once the list is done
          while (next(connections, 1, out, got) == 0 && got.value == 1) {
            final connection = out.value;
            try {
              final isConnected = _slot<_OutInt16Native>(connection, _connectionIsConnected).asFunction<_OutInt16>();
              if (isConnected(connection, connected) < 0 || connected.value != variantTrue) {
                continue;
              }
              final adapterId = _slot<_OutGuidNative>(connection, _connectionGetAdapterId).asFunction<_OutGuid>();
              if (adapterId(connection, guidOut) < 0) {
                continue;
              }
              final adapter = guidString(Uint8List.fromList(guidOut.asTypedList(16)));
              final getNetwork = _slot<_OutPointerNative>(connection, _connectionGetNetwork).asFunction<_OutPointer>();
              if (getNetwork(connection, out) < 0) {
                continue;
              }
              final network = out.value;
              try {
                final getCategory = _slot<_OutInt32Native>(network, _networkGetCategory).asFunction<_OutInt32>();
                final networkId = _slot<_OutGuidNative>(network, _networkGetNetworkId).asFunction<_OutGuid>();
                final known = getCategory(network, category) >= 0 ? windowsNetworkCategory(category.value) : null;
                if (known != null && networkId(network, guidOut) >= 0) {
                  categories[adapter] = (known, guidString(Uint8List.fromList(guidOut.asTypedList(16))));
                }
              } finally {
                _releaseObject(network);
              }
            } finally {
              _releaseObject(connection);
            }
          }
        } finally {
          _releaseObject(connections);
        }
      } finally {
        _releaseObject(manager);
      }
      return categories;
    });
  } finally {
    // Balanced only when this call initialised COM on the thread (S_OK, or S_FALSE when it already was)
    if (initialized >= 0) {
      coUninitialize();
    }
  }
}
