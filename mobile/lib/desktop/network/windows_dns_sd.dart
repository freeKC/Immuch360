// mDNS / DNS-SD on Windows through the DNS-SD functions of dnsapi.dll (Windows 10 and later), in place of
// bonsoir_windows on the computers: the search for the servers that announce themselves (the network discovery,
// network_discovery_probes.dart) and the announcement of "Share this computer on the network" (phone_share.provider.dart).
//
// bonsoir_windows 5.1.5 crashed the app (an access violation in its DLL on a dnsapi thread, 27 s after a start): it
// handles the browse, resolve and register callbacks on the threads of dnsapi, changes its lists there without a lock,
// sends to the Flutter channels from there, and keeps the address of a cancel handle that lives on the stack. Here each
// callback is a NativeCallable.listener: the thread of dnsapi only posts the call to this isolate and returns, and
// everything else runs on the event loop of the isolate, one call at a time. What dnsapi hands over (record lists,
// service instances) stays valid until it is freed here, once read, as its documentation asks; what this side gives
// (requests, names, cancel handles) is freed once dnsapi said it is done with it, and kept otherwise. The callbacks
// are made once and never closed, since dnsapi may call them late; a late call finds no handler and only frees what it
// carries.
//
// How dnsapi behaves where its documentation says nothing, as measured on Windows 11 25H2 (build 26220): a resolution
// nobody answers never ends by itself (no callback in 70 s), so it is cancelled after a few seconds, and its cancel
// calls back once with ERROR_CANCELLED; a resolution that answered stays known to dnsapi until it is cancelled, whose
// cancel then succeeds and calls back no more; a browse cancelled calls back once with ERROR_CANCELLED; a registration
// cancelled while pending never calls back, and one cancelled once registered stays announced. So a registration is
// never cancelled here: a withdrawal asked during its registration waits for it, then withdraws it.
//
// The announcement of the share also follows the networks the share listens on (interface_rank.dart): it is registered
// on the interface of the first served address only, with that address, so that a network the public rule leaves out
// (a café's Wi-Fi next to the office's Ethernet) never hears the computer's name and the share's user, and it is
// withdrawn while no address is served. bonsoir registered on every interface.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart' show phoneShareServiceType;
import 'package:logging/logging.dart';

final _log = Logger('WindowsDnsSd');

const _errorSuccess = 0;
const _errorCancelled = 1223;
const _dnsRequestPending = 9506;
const _dnsQueryRequestVersion1 = 1;
const _dnsFreeRecordList = 1;
const _dnsTypePtr = 12;
const _dnsTypeText = 16;

/// How long a service found by the browse has to answer its resolution
const _resolveTimeout = Duration(seconds: 5);

// ---------------------------------------------------------------------------------------------------------------------
// The structures of windns.h and windnsdef.h (Windows SDK 10.0.26100), 64 bit layout

/// DNS_SERVICE_INSTANCE
final class _DnsServiceInstance extends Struct {
  external Pointer<Utf16> instanceName;
  external Pointer<Utf16> hostName;

  /// IP4_ADDRESS, in network byte order
  external Pointer<Uint32> ip4Address;
  external Pointer<Void> ip6Address;
  @Uint16()
  external int port;
  @Uint16()
  external int priority;
  @Uint16()
  external int weight;
  @Uint32()
  external int propertyCount;
  external Pointer<Pointer<Utf16>> keys;
  external Pointer<Pointer<Utf16>> values;
  @Uint32()
  external int interfaceIndex;
}

/// DNS_SERVICE_CANCEL
final class _DnsServiceCancel extends Struct {
  external Pointer<Void> reserved;
}

/// DNS_SERVICE_BROWSE_REQUEST, version 1: pBrowseCallback in the union
final class _DnsServiceBrowseRequest extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int interfaceIndex;
  external Pointer<Utf16> queryName;
  external Pointer<NativeFunction<_BrowseCallbackNative>> callback;
  external Pointer<Void> context;
}

/// DNS_SERVICE_RESOLVE_REQUEST
final class _DnsServiceResolveRequest extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int interfaceIndex;
  external Pointer<Utf16> queryName;
  external Pointer<NativeFunction<_InstanceCallbackNative>> callback;
  external Pointer<Void> context;
}

/// DNS_SERVICE_REGISTER_REQUEST
final class _DnsServiceRegisterRequest extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int interfaceIndex;
  external Pointer<_DnsServiceInstance> instance;
  external Pointer<NativeFunction<_InstanceCallbackNative>> callback;
  external Pointer<Void> context;
  external Pointer<Void> credentials;
  @Int32()
  external int unicastEnabled;
}

/// DNS_RECORDW up to its Data union, which starts right after, 8 byte aligned
final class _DnsRecord extends Struct {
  external Pointer<_DnsRecord> next;
  external Pointer<Utf16> name;
  @Uint16()
  external int type;
  @Uint16()
  external int dataLength;
  @Uint32()
  external int flags;
  @Uint32()
  external int ttl;
  @Uint32()
  external int reserved;
}

/// The sizes the structures above must have, checked by the tests against the C layout
@visibleForTesting
Map<String, int> get windowsDnsSdStructSizes => {
  'DNS_SERVICE_INSTANCE': sizeOf<_DnsServiceInstance>(),
  'DNS_SERVICE_CANCEL': sizeOf<_DnsServiceCancel>(),
  'DNS_SERVICE_BROWSE_REQUEST': sizeOf<_DnsServiceBrowseRequest>(),
  'DNS_SERVICE_RESOLVE_REQUEST': sizeOf<_DnsServiceResolveRequest>(),
  'DNS_SERVICE_REGISTER_REQUEST': sizeOf<_DnsServiceRegisterRequest>(),
  'DNS_RECORDW header': sizeOf<_DnsRecord>(),
};

typedef _BrowseCallbackNative = Void Function(Uint32 status, Pointer<Void> context, Pointer<_DnsRecord> records);
typedef _InstanceCallbackNative =
    Void Function(Uint32 status, Pointer<Void> context, Pointer<_DnsServiceInstance> instance);

typedef _BrowseNative = Int32 Function(Pointer<_DnsServiceBrowseRequest> request, Pointer<_DnsServiceCancel> cancel);
typedef _Browse = int Function(Pointer<_DnsServiceBrowseRequest> request, Pointer<_DnsServiceCancel> cancel);
typedef _ResolveNative = Int32 Function(Pointer<_DnsServiceResolveRequest> request, Pointer<_DnsServiceCancel> cancel);
typedef _Resolve = int Function(Pointer<_DnsServiceResolveRequest> request, Pointer<_DnsServiceCancel> cancel);
typedef _RegisterNative =
    Uint32 Function(Pointer<_DnsServiceRegisterRequest> request, Pointer<_DnsServiceCancel> cancel);
typedef _Register = int Function(Pointer<_DnsServiceRegisterRequest> request, Pointer<_DnsServiceCancel> cancel);
typedef _CancelNative = Int32 Function(Pointer<_DnsServiceCancel> cancel);
typedef _Cancel = int Function(Pointer<_DnsServiceCancel> cancel);
typedef _ConstructInstanceNative =
    Pointer<_DnsServiceInstance> Function(
      Pointer<Utf16> serviceName,
      Pointer<Utf16> hostName,
      Pointer<Uint32> ip4,
      Pointer<Void> ip6,
      Uint16 port,
      Uint16 priority,
      Uint16 weight,
      Uint32 propertyCount,
      Pointer<Pointer<Utf16>> keys,
      Pointer<Pointer<Utf16>> values,
    );
typedef _ConstructInstance =
    Pointer<_DnsServiceInstance> Function(
      Pointer<Utf16> serviceName,
      Pointer<Utf16> hostName,
      Pointer<Uint32> ip4,
      Pointer<Void> ip6,
      int port,
      int priority,
      int weight,
      int propertyCount,
      Pointer<Pointer<Utf16>> keys,
      Pointer<Pointer<Utf16>> values,
    );
typedef _FreeInstanceNative = Void Function(Pointer<_DnsServiceInstance> instance);
typedef _FreeInstance = void Function(Pointer<_DnsServiceInstance> instance);
typedef _DnsFreeNative = Void Function(Pointer<Void> data, Int32 type);
typedef _DnsFree = void Function(Pointer<Void> data, int type);

// ---------------------------------------------------------------------------------------------------------------------
// Reading what dnsapi hands over

/// One instance a browse callback tells of
@immutable
@visibleForTesting
class DnsSdBrowseRecord {
  const DnsSdBrowseRecord({required this.fullName, required this.alive, this.attributes = const {}});

  /// "Name._smb._tcp.local", what a resolution asks for
  final String fullName;

  /// False when the instance goes away (a time to live of 0)
  final bool alive;

  /// Its TXT record when it came with it
  final Map<String, String> attributes;
}

/// The instances a browse callback tells of, from the record list [list] (DNS_RECORDW): its PTR records, with the TXT
/// records of the same names. Nothing is freed here.
@visibleForTesting
List<DnsSdBrowseRecord> readBrowseRecords(Pointer<Void> list) {
  final instances = <String, bool>{};
  final texts = <String, Map<String, String>>{};
  for (var record = list.cast<_DnsRecord>(); record != nullptr; record = record.ref.next) {
    final data = Pointer<Uint8>.fromAddress(record.address + sizeOf<_DnsRecord>());
    switch (record.ref.type) {
      case _dnsTypePtr:
        final target = data.cast<Pointer<Utf16>>().value;
        if (target != nullptr) {
          final name = target.toDartString();
          if (name.isNotEmpty) {
            instances[name] = (instances[name] ?? false) || record.ref.ttl > 0;
          }
        }
      case _dnsTypeText:
        if (record.ref.name != nullptr) {
          final count = data.cast<Uint32>().value;
          // pStringArray follows the count, at the alignment of a pointer
          final strings = Pointer<Pointer<Utf16>>.fromAddress(data.address + sizeOf<Pointer<Void>>());
          texts[_withoutDot(record.ref.name.toDartString()).toLowerCase()] = txtAttributes([
            for (var i = 0; i < count; i++)
              if (strings[i] != nullptr) strings[i].toDartString(),
          ]);
        }
    }
  }
  return [
    for (final MapEntry(key: name, value: alive) in instances.entries)
      DnsSdBrowseRecord(fullName: name, alive: alive, attributes: texts[_withoutDot(name).toLowerCase()] ?? const {}),
  ];
}

/// The "key=value" strings of a TXT record as attributes; a key without "=" has an empty value, the first of a key
/// wins (RFC 6763, 6.4)
@visibleForTesting
Map<String, String> txtAttributes(Iterable<String> strings) {
  final attributes = <String, String>{};
  for (final string in strings) {
    final split = string.indexOf('=');
    final key = split < 0 ? string : string.substring(0, split);
    if (key.isEmpty) {
      continue;
    }
    attributes.putIfAbsent(key, () => split < 0 ? '' : string.substring(split + 1));
  }
  return attributes;
}

/// The service a resolution found, from [instance] (DNS_SERVICE_INSTANCE) of a service of [type]; null without a host
/// or a port. The IPv4 address serves as the host when there is one: the phones get an address from their resolvers
/// too. [fallbackAttributes] serve when the instance carries no property. Nothing is freed here.
@visibleForTesting
MdnsService? serviceOfInstance(
  Pointer<Void> instance,
  String type, {
  Map<String, String> fallbackAttributes = const {},
}) {
  if (instance == nullptr) {
    return null;
  }
  final ref = instance.cast<_DnsServiceInstance>().ref;
  final fullName = ref.instanceName == nullptr ? '' : ref.instanceName.toDartString();
  var host = '';
  if (ref.ip4Address != nullptr) {
    final address = ref.ip4Address.cast<Uint8>().asTypedList(4).join('.');
    // An instance with an IPv6 address only gives an empty IPv4 one
    if (address != '0.0.0.0') {
      host = address;
    }
  }
  if (host.isEmpty && ref.hostName != nullptr) {
    host = _withoutDot(ref.hostName.toDartString());
  }
  if (host.isEmpty || ref.port == 0) {
    return null;
  }
  final attributes = <String, String>{};
  for (var i = 0; i < ref.propertyCount && ref.keys != nullptr; i++) {
    final key = ref.keys[i] == nullptr ? '' : ref.keys[i].toDartString();
    if (key.isEmpty) {
      continue;
    }
    final value = ref.values == nullptr || ref.values[i] == nullptr ? '' : ref.values[i].toDartString();
    attributes.putIfAbsent(key, () => value);
  }
  return MdnsService(
    name: dnsSdInstanceName(fullName, type),
    type: type,
    host: host,
    port: ref.port,
    attributes: attributes.isEmpty ? fallbackAttributes : attributes,
  );
}

/// The instance label of [fullName] ("My NAS._smb._tcp.local") for a service of [type] ("_smb._tcp"), its escapes
/// read ("\." for a dot, "\032" for a byte by its decimal value)
@visibleForTesting
String dnsSdInstanceName(String fullName, String type) {
  var label = _withoutDot(fullName);
  final at = label.toLowerCase().indexOf('.${type.toLowerCase()}');
  if (at > 0) {
    label = label.substring(0, at);
  } else {
    final split = label.indexOf('._');
    if (split > 0) {
      label = label.substring(0, split);
    }
  }
  return _unescape(label);
}

/// [label] as an instance label in a full name: dots and backslashes escaped
@visibleForTesting
String dnsSdEscapeLabel(String label) => label.replaceAll(r'\', r'\\').replaceAll('.', r'\.');

final _decimalEscape = RegExp(r'^\d{3}$');

String _unescape(String label) {
  if (!label.contains(r'\')) {
    return label;
  }
  final out = StringBuffer();
  final codes = <int>[];
  void flush() {
    if (codes.isNotEmpty) {
      out.write(utf8.decode(codes, allowMalformed: true));
      codes.clear();
    }
  }

  for (var i = 0; i < label.length; i++) {
    final char = label[i];
    final byte = char == r'\' && i + 3 < label.length && _decimalEscape.hasMatch(label.substring(i + 1, i + 4))
        ? int.parse(label.substring(i + 1, i + 4))
        : null;
    if (byte != null && byte < 256) {
      // A byte of the UTF-8 label by its decimal value
      codes.add(byte);
      i += 3;
      continue;
    }
    flush();
    if (char == r'\' && i + 1 < label.length) {
      out.write(label[++i]);
    } else {
      out.write(char);
    }
  }
  flush();
  return out.toString();
}

String _withoutDot(String name) => name.endsWith('.') ? name.substring(0, name.length - 1) : name;

// ---------------------------------------------------------------------------------------------------------------------
// dnsapi and its callbacks

typedef _BrowseHandler = void Function(int status, Pointer<_DnsRecord> records);
typedef _InstanceHandler = void Function(int status, Pointer<_DnsServiceInstance> instance);

/// The DNS-SD functions of dnsapi.dll and the two callbacks, made once for the life of the isolate
class _DnsSd {
  _DnsSd._(DynamicLibrary dnsapi)
    : browse = dnsapi.lookupFunction<_BrowseNative, _Browse>('DnsServiceBrowse'),
      browseCancel = dnsapi.lookupFunction<_CancelNative, _Cancel>('DnsServiceBrowseCancel'),
      resolve = dnsapi.lookupFunction<_ResolveNative, _Resolve>('DnsServiceResolve'),
      resolveCancel = dnsapi.lookupFunction<_CancelNative, _Cancel>('DnsServiceResolveCancel'),
      register = dnsapi.lookupFunction<_RegisterNative, _Register>('DnsServiceRegister'),
      deregister = dnsapi.lookupFunction<_RegisterNative, _Register>('DnsServiceDeRegister'),
      constructInstance = dnsapi.lookupFunction<_ConstructInstanceNative, _ConstructInstance>(
        'DnsServiceConstructInstance',
      ),
      freeInstance = dnsapi.lookupFunction<_FreeInstanceNative, _FreeInstance>('DnsServiceFreeInstance'),
      dnsFree = dnsapi.lookupFunction<_DnsFreeNative, _DnsFree>('DnsFree');

  static _DnsSd? _instance;

  /// Throws where dnsapi.dll or its DNS-SD functions are missing (not Windows, Windows before 10)
  static _DnsSd get instance => _instance ??= _DnsSd._(DynamicLibrary.open('dnsapi.dll'));

  static var _nextId = 0;

  /// A context for a request: its handler is found by it, so that no Dart object goes through native code
  static int nextId() => ++_nextId;

  final _Browse browse;
  final _Cancel browseCancel;
  final _Resolve resolve;
  final _Cancel resolveCancel;
  final _Register register;
  final _Register deregister;
  final _ConstructInstance constructInstance;
  final _FreeInstance freeInstance;
  final _DnsFree dnsFree;

  final browseHandlers = <int, _BrowseHandler>{};
  final instanceHandlers = <int, _InstanceHandler>{};

  // Never closed: dnsapi may call them after a request ended (see the top of this file). They do not keep the isolate
  // alive either: the app's lives as long as its window, and a test's must end with its tests.
  late final browseCallback = NativeCallable<_BrowseCallbackNative>.listener(_onBrowse)..keepIsolateAlive = false;
  late final instanceCallback = NativeCallable<_InstanceCallbackNative>.listener(_onInstance)..keepIsolateAlive = false;

  static void _onBrowse(int status, Pointer<Void> context, Pointer<_DnsRecord> records) {
    final dns = _instance!;
    try {
      dns.browseHandlers[context.address]?.call(status, records);
    } catch (error, stackTrace) {
      _log.warning('mDNS browse callback', error, stackTrace);
    } finally {
      if (records != nullptr) {
        dns.dnsFree(records.cast(), _dnsFreeRecordList);
      }
    }
  }

  static void _onInstance(int status, Pointer<Void> context, Pointer<_DnsServiceInstance> instance) {
    final dns = _instance!;
    try {
      dns.instanceHandlers[context.address]?.call(status, instance);
    } catch (error, stackTrace) {
      _log.warning('mDNS callback', error, stackTrace);
    } finally {
      // A resolution's answer, or the copy a registration and its withdrawal give back: freed by the caller
      if (instance != nullptr) {
        dns.freeInstance(instance);
      }
    }
  }
}

/// How many browses, resolutions and registrations dnsapi has not said it is done with
@visibleForTesting
int get windowsDnsSdPending {
  final dns = _DnsSd._instance;
  return dns == null ? 0 : dns.browseHandlers.length + dns.instanceHandlers.length;
}

// ---------------------------------------------------------------------------------------------------------------------
// Browse

/// The resolved services of one mDNS [type] ("_smb._tcp") until [until] completes, through dnsapi: what bonsoirBrowse
/// gives on the phones. Any failure ends the stream without an error.
Stream<MdnsService> windowsDnsSdBrowse(String type, Future<void> until) {
  final controller = StreamController<MdnsService>();
  _WindowsBrowse? browse;
  controller.onListen = () {
    try {
      browse = _WindowsBrowse.start(type, controller);
    } catch (error) {
      _log.fine('mDNS $type is not available: $error');
    }
    final started = browse;
    if (started == null) {
      unawaited(controller.close());
      return;
    }
    unawaited(until.whenComplete(started.stop));
  };
  controller.onCancel = () => browse?.stop();
  return controller.stream;
}

class _WindowsBrowse {
  _WindowsBrowse._(this._dns, this.type, this._out);

  final _DnsSd _dns;
  final String type;
  final StreamController<MdnsService> _out;
  final _id = _DnsSd.nextId();
  final _queryName = calloc<Pointer<Utf16>>();
  final _request = calloc<_DnsServiceBrowseRequest>();
  final _cancel = calloc<_DnsServiceCancel>();
  final _seen = <String>{};
  final _resolves = <_WindowsResolve>{};
  var _stopped = false;

  /// Null when dnsapi refused the browse
  static _WindowsBrowse? start(String type, StreamController<MdnsService> out) {
    final browse = _WindowsBrowse._(_DnsSd.instance, type, out);
    return browse._begin() ? browse : null;
  }

  bool _begin() {
    _queryName.value = '$type.local'.toNativeUtf16(allocator: calloc);
    _request.ref
      ..version = _dnsQueryRequestVersion1
      ..interfaceIndex = 0
      ..queryName = _queryName.value
      ..callback = _dns.browseCallback.nativeFunction
      ..context = Pointer.fromAddress(_id);
    _dns.browseHandlers[_id] = _onRecords;
    final status = _dns.browse(_request, _cancel);
    if (status != _dnsRequestPending) {
      _log.fine('mDNS $type did not start: $status');
      _release();
      return false;
    }
    return true;
  }

  void _onRecords(int status, Pointer<_DnsRecord> records) {
    if (status != _errorSuccess) {
      // Cancelled, or failed: dnsapi calls no more for this browse, and a failed one is not cancelled
      if (status != _errorCancelled) {
        _log.fine('mDNS $type ended: $status');
      }
      _release();
      stop();
      return;
    }
    if (_stopped || records == nullptr) {
      return;
    }
    for (final record in readBrowseRecords(records.cast())) {
      if (record.alive && _seen.add(record.fullName.toLowerCase())) {
        final resolve = _WindowsResolve.start(_dns, record, type, onDone: _onResolved);
        if (resolve != null) {
          _resolves.add(resolve);
        }
      }
    }
  }

  void _onResolved(_WindowsResolve resolve, MdnsService? service) {
    _resolves.remove(resolve);
    if (service != null && !_stopped && !_out.isClosed) {
      _out.add(service);
    }
  }

  /// Ends the browse and the resolutions under way; the memory goes once dnsapi confirms
  void stop() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    for (final resolve in _resolves.toList()) {
      resolve.cancel();
    }
    if (_dns.browseHandlers.containsKey(_id)) {
      final status = _dns.browseCancel(_cancel);
      if (status != _errorSuccess) {
        _log.fine('mDNS $type, cancel: $status');
      }
    }
    if (!_out.isClosed) {
      unawaited(_out.close());
    }
  }

  void _release() {
    if (_dns.browseHandlers.remove(_id) == null) {
      return;
    }
    // Freed once dnsapi called for the last time; stop() then has nothing to cancel
    calloc.free(_queryName.value);
    calloc.free(_queryName);
    calloc.free(_request);
    calloc.free(_cancel);
  }
}

class _WindowsResolve {
  _WindowsResolve._(this._dns, this._record, this._type, this._onDone);

  final _DnsSd _dns;
  final DnsSdBrowseRecord _record;
  final String _type;
  final void Function(_WindowsResolve resolve, MdnsService? service) _onDone;
  final _id = _DnsSd.nextId();
  final _queryName = calloc<Pointer<Utf16>>();
  final _request = calloc<_DnsServiceResolveRequest>();
  final _cancel = calloc<_DnsServiceCancel>();
  Timer? _timeout;
  var _cancelled = false;

  /// Null when dnsapi refused the resolution
  static _WindowsResolve? start(
    _DnsSd dns,
    DnsSdBrowseRecord record,
    String type, {
    required void Function(_WindowsResolve resolve, MdnsService? service) onDone,
  }) {
    final resolve = _WindowsResolve._(dns, record, type, onDone);
    return resolve._begin() ? resolve : null;
  }

  bool _begin() {
    _queryName.value = _record.fullName.toNativeUtf16(allocator: calloc);
    _request.ref
      ..version = _dnsQueryRequestVersion1
      ..interfaceIndex = 0
      ..queryName = _queryName.value
      ..callback = _dns.instanceCallback.nativeFunction
      ..context = Pointer.fromAddress(_id);
    _dns.instanceHandlers[_id] = _onInstance;
    final status = _dns.resolve(_request, _cancel);
    if (status != _dnsRequestPending) {
      _log.fine('mDNS resolution did not start: $status');
      _release();
      return false;
    }
    _timeout = Timer(_resolveTimeout, cancel);
    return true;
  }

  void _onInstance(int status, Pointer<_DnsServiceInstance> instance) {
    // A resolution answers once, whatever the outcome
    _timeout?.cancel();
    MdnsService? service;
    if (status == _errorSuccess && !_cancelled) {
      service = serviceOfInstance(instance.cast(), _type, fallbackAttributes: _record.attributes);
    } else if (status != _errorCancelled) {
      _log.fine('mDNS resolution failed: $status');
    }
    if (status != _errorCancelled && !_cancelled) {
      // dnsapi keeps a resolution that answered until it is cancelled (see the top of this file)
      _cancelled = true;
      _dns.resolveCancel(_cancel);
    }
    _release();
    _onDone(this, service);
  }

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _timeout?.cancel();
    if (_dns.instanceHandlers.containsKey(_id)) {
      _dns.resolveCancel(_cancel);
    }
  }

  void _release() {
    if (_dns.instanceHandlers.remove(_id) == null) {
      return;
    }
    calloc.free(_queryName.value);
    calloc.free(_queryName);
    calloc.free(_request);
    calloc.free(_cancel);
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Register

/// A service announced on the network, until [stop]
abstract interface class DnsSdAnnouncement {
  Future<void> stop();
}

/// Announces [name] as a service of [type] on [port] on the interface [interfaceIndex] only, with [address] (IPv4,
/// dotted) as the address of this computer's host name there; null when dnsapi refused it
typedef DnsSdRegister =
    DnsSdAnnouncement? Function({
      required String name,
      required String type,
      required int port,
      required Map<String, String> attributes,
      required int interfaceIndex,
      required String address,
    });

/// [DnsSdRegister] through dnsapi
DnsSdAnnouncement? registerWindowsDnsSd({
  required String name,
  required String type,
  required int port,
  required Map<String, String> attributes,
  required int interfaceIndex,
  required String address,
}) {
  try {
    final registration = _WindowsRegistration._(_DnsSd.instance);
    return registration._begin(
          name: name,
          type: type,
          port: port,
          attributes: attributes,
          interfaceIndex: interfaceIndex,
          address: address,
        )
        ? registration
        : null;
  } catch (error) {
    _log.warning('The share cannot be announced on this computer: $error');
    return null;
  }
}

enum _RegistrationState { registering, registered, withdrawWhenRegistered, withdrawing, done }

class _WindowsRegistration implements DnsSdAnnouncement {
  _WindowsRegistration._(this._dns);

  final _DnsSd _dns;
  final _id = _DnsSd.nextId();
  final _request = calloc<_DnsServiceRegisterRequest>();
  final _cancel = calloc<_DnsServiceCancel>();
  final _address = calloc<Uint32>();
  final _strings = <Pointer<Utf16>>[];
  Pointer<Pointer<Utf16>> _keys = nullptr;
  Pointer<Pointer<Utf16>> _values = nullptr;
  Pointer<_DnsServiceInstance> _instance = nullptr;
  var _state = _RegistrationState.registering;
  var _released = false;
  final _withdrawn = Completer<void>();
  var _description = '';

  Pointer<Utf16> _string(String text) {
    final pointer = text.toNativeUtf16(allocator: calloc);
    _strings.add(pointer);
    return pointer;
  }

  bool _begin({
    required String name,
    required String type,
    required int port,
    required Map<String, String> attributes,
    required int interfaceIndex,
    required String address,
  }) {
    _description = '$name ($type, port $port, interface $interfaceIndex)';
    final ip = InternetAddress.tryParse(address);
    if (ip == null || ip.type != InternetAddressType.IPv4) {
      _log.fine('mDNS: no IPv4 address to announce $_description');
      _finish();
      return false;
    }
    // IP4_ADDRESS is in network byte order: the bytes as they are written
    _address.cast<Uint8>().asTypedList(4).setAll(0, ip.rawAddress);

    final entries = attributes.entries.toList();
    _keys = calloc<Pointer<Utf16>>(entries.length + 1);
    _values = calloc<Pointer<Utf16>>(entries.length + 1);
    for (final (index, entry) in entries.indexed) {
      _keys[index] = _string(entry.key);
      _values[index] = _string(entry.value);
    }
    // The short host name, as the system answers it on mDNS
    final hostName = Platform.localHostname.split('.').first;
    _instance = _dns.constructInstance(
      _string('${dnsSdEscapeLabel(name)}.$type.local'),
      _string('${hostName.isEmpty ? 'computer' : hostName}.local'),
      _address,
      nullptr,
      port,
      0,
      0,
      entries.length,
      _keys,
      _values,
    );
    if (_instance == nullptr) {
      _log.fine('mDNS: no instance for $_description');
      _finish();
      return false;
    }
    _request.ref
      ..version = _dnsQueryRequestVersion1
      ..interfaceIndex = interfaceIndex
      ..instance = _instance
      ..callback = _dns.instanceCallback.nativeFunction
      ..context = Pointer.fromAddress(_id)
      ..credentials = nullptr
      ..unicastEnabled = 0;
    _dns.instanceHandlers[_id] = _onCallback;
    final status = _dns.register(_request, _cancel);
    if (status != _dnsRequestPending) {
      _log.warning('mDNS: $_description is not announced: $status');
      _finish();
      return false;
    }
    return true;
  }

  void _onCallback(int status, Pointer<_DnsServiceInstance> _) {
    switch (_state) {
      case _RegistrationState.registering:
        if (status == _errorSuccess) {
          _state = _RegistrationState.registered;
          _log.fine('mDNS: $_description announced');
        } else {
          // Refused: nothing stays registered
          _log.warning('mDNS: $_description is not announced: $status');
          _finish();
        }
      case _RegistrationState.withdrawWhenRegistered:
        // Stopped while it registered: withdrawn as soon as it is there, so that it does not outlive the share
        if (status == _errorSuccess) {
          _withdraw();
        } else {
          _finish();
        }
      case _RegistrationState.withdrawing:
        _finish();
      case _RegistrationState.registered || _RegistrationState.done:
        break;
    }
  }

  void _withdraw() {
    _state = _RegistrationState.withdrawing;
    final status = _dns.deregister(_request, nullptr);
    if (status != _dnsRequestPending) {
      _log.fine('mDNS: $_description, withdrawal: $status');
      _finish();
    }
  }

  @override
  Future<void> stop() async {
    switch (_state) {
      case _RegistrationState.registered:
        _withdraw();
      case _RegistrationState.registering:
        // Not cancelled: dnsapi would keep it announced, or never call back (see the top of this file)
        _state = _RegistrationState.withdrawWhenRegistered;
      case _RegistrationState.withdrawWhenRegistered || _RegistrationState.withdrawing || _RegistrationState.done:
        break;
    }
    // The memory stays until dnsapi answers; the share does not wait longer than this for it
    await _withdrawn.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  /// dnsapi is done with this registration: what was given to it goes
  void _finish() {
    _state = _RegistrationState.done;
    if (!_released) {
      _released = true;
      _dns.instanceHandlers.remove(_id);
      if (_instance != nullptr) {
        _dns.freeInstance(_instance);
        _instance = nullptr;
      }
      for (final string in _strings) {
        calloc.free(string);
      }
      _strings.clear();
      if (_keys != nullptr) {
        calloc.free(_keys);
        _keys = nullptr;
      }
      if (_values != nullptr) {
        calloc.free(_values);
        _values = nullptr;
      }
      calloc.free(_request);
      calloc.free(_cancel);
      calloc.free(_address);
    }
    if (!_withdrawn.isCompleted) {
      _withdrawn.complete();
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// The announcement of the computer share

/// The interface the share announces itself on and the address it gives there: those of the first address it listens
/// on, in the order of the ranking; null while it listens on none
typedef ServedInterface = Future<(int, String)?> Function();

/// [ServedInterface] from the network interfaces of this computer and the public network rule
Future<(int, String)?> servedShareInterface() async {
  final served = await desktopShareLocalAddresses();
  if (served.isEmpty) {
    return null;
  }
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  for (final interface in interfaces) {
    // Index 0 would announce on every interface, which is what this avoids
    if (interface.index > 0 && interface.addresses.any((address) => address.address == served.first)) {
      return (interface.index, served.first);
    }
  }
  return null;
}

/// The announcement of "Share this computer on the network", following the networks the share listens on (see the
/// top of this file)
class WindowsShareAnnouncer {
  WindowsShareAnnouncer({
    required this.name,
    required this.port,
    required this.attributes,
    this.type = phoneShareServiceType,
    this.servedInterface = servedShareInterface,
    this.register = registerWindowsDnsSd,
    this.refreshEvery = const Duration(seconds: 5),
    this.networkChanges,
  });

  final String name;
  final String type;
  final int port;
  final Map<String, String> attributes;
  final ServedInterface servedInterface;
  final DnsSdRegister register;

  /// As often as the share looks at the addresses it listens on
  final Duration refreshEvery;

  /// The network changes the system reports, looked at at once rather than at the next tick, as the share's server
  /// does: a laptop that wakes up in a café stops announcing itself there as soon as Windows tells
  final Stream<void>? networkChanges;

  DnsSdAnnouncement? _current;
  (int, String)? _target;
  Timer? _timer;
  StreamSubscription<void>? _changes;
  Future<void> _queue = Future.value();
  var _stopped = false;

  /// The interface and address announced now, null when nothing is
  @visibleForTesting
  (int, String)? get announcedOn => _current == null ? null : _target;

  Future<void> start() async {
    await _sync();
    if (!_stopped) {
      _timer = Timer.periodic(refreshEvery, (_) => unawaited(_sync()));
      _changes = networkChanges?.listen(
        (_) => unawaited(_sync()),
        onError: (Object error) => _log.fine('Network changes: $error'),
      );
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _changes?.cancel();
    _changes = null;
    await _queue;
    final current = _current;
    _current = null;
    _target = null;
    await current?.stop();
  }

  /// Looks at the networks of the share now rather than at the next tick
  @visibleForTesting
  Future<void> refresh() => _sync();

  Future<void> _sync() => _queue = _queue.then((_) => _syncNow()).catchError((Object error) {
    _log.fine('The announcement of the share did not follow the network: $error');
  });

  Future<void> _syncNow() async {
    if (_stopped) {
      return;
    }
    (int, String)? target;
    try {
      target = await servedInterface();
    } catch (error) {
      _log.fine('No network interface: $error');
    }
    // A refused registration is tried again only when the network changes
    if (_stopped || target == _target) {
      return;
    }
    final previous = _current;
    _current = null;
    _target = target;
    await previous?.stop();
    if (target == null) {
      _log.info('The share of this computer is not announced: it listens on no network');
      return;
    }
    final (index, address) = target;
    _current = register(
      name: name,
      type: type,
      port: port,
      attributes: attributes,
      interfaceIndex: index,
      address: address,
    );
  }
}

/// Announces the share of this computer through dnsapi, on the network it listens on only; gives what stops the
/// announcement. What phone_share.provider.dart's bonsoirAdvertise does on the phones.
Future<Future<void> Function()> windowsShareAdvertise(String name, int port, Map<String, String> attributes) async {
  final announcer = WindowsShareAnnouncer(
    name: name,
    port: port,
    attributes: attributes,
    networkChanges: Connectivity().onConnectivityChanged.map<void>((_) {}),
  );
  await announcer.start();
  return announcer.stop;
}
