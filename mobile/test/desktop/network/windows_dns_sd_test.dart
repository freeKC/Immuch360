import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/windows_dns_sd.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';

/// Native memory laid out as dnsapi lays it out, freed at the end of each test
class _Native {
  final _blocks = <Pointer<Uint8>>[];

  Pointer<Uint8> bytes(int size) {
    final block = calloc<Uint8>(size);
    _blocks.add(block);
    return block;
  }

  Pointer<Utf16> text(String value) {
    final pointer = value.toNativeUtf16(allocator: calloc);
    _blocks.add(pointer.cast());
    return pointer;
  }

  void setPointer(Pointer<Uint8> base, int offset, Pointer<NativeType> value) =>
      Pointer<Pointer<NativeType>>.fromAddress(base.address + offset).value = value;

  void setUint16(Pointer<Uint8> base, int offset, int value) =>
      Pointer<Uint16>.fromAddress(base.address + offset).value = value;

  void setUint32(Pointer<Uint8> base, int offset, int value) =>
      Pointer<Uint32>.fromAddress(base.address + offset).value = value;

  /// A DNS_RECORDW: pNext 0, pName 8, wType 16, dwTtl 24, Data 32, with room for [dataSize] bytes of data
  Pointer<Uint8> record({
    required String name,
    required int type,
    required int ttl,
    Pointer<Uint8>? next,
    int dataSize = 8,
  }) {
    final record = bytes(32 + dataSize);
    setPointer(record, 0, next ?? nullptr);
    setPointer(record, 8, text(name));
    setUint16(record, 16, type);
    setUint32(record, 24, ttl);
    return record;
  }

  Pointer<Uint8> ptr(String name, String target, {int ttl = 120, Pointer<Uint8>? next}) {
    final record = this.record(name: name, type: 12, ttl: ttl, next: next);
    setPointer(record, 32, text(target));
    return record;
  }

  /// DNS_TXT_DATAW: dwStringCount 32, pStringArray 40
  Pointer<Uint8> txt(String name, List<String> strings, {Pointer<Uint8>? next}) {
    final record = this.record(name: name, type: 16, ttl: 120, next: next, dataSize: 8 + 8 * strings.length);
    setUint32(record, 32, strings.length);
    for (final (index, string) in strings.indexed) {
      setPointer(record, 40 + 8 * index, text(string));
    }
    return record;
  }

  /// A DNS_SERVICE_INSTANCE: names 0 and 8, ip4 16, ip6 24, wPort 32, dwPropertyCount 40, keys 48, values 56
  Pointer<Uint8> instance({
    required String fullName,
    String? host,
    List<int>? ip4,
    required int port,
    Map<String, String> properties = const {},
  }) {
    final instance = bytes(72);
    setPointer(instance, 0, text(fullName));
    setPointer(instance, 8, host == null ? nullptr : text(host));
    if (ip4 != null) {
      final address = bytes(4)..asTypedList(4).setAll(0, ip4);
      setPointer(instance, 16, address);
    }
    setUint16(instance, 32, port);
    setUint32(instance, 40, properties.length);
    final keys = bytes(8 * max(properties.length, 1));
    final values = bytes(8 * max(properties.length, 1));
    for (final (index, MapEntry(:key, :value)) in properties.entries.indexed) {
      setPointer(keys, 8 * index, text(key));
      setPointer(values, 8 * index, text(value));
    }
    setPointer(instance, 48, keys);
    setPointer(instance, 56, values);
    return instance;
  }

  void free() {
    for (final block in _blocks) {
      calloc.free(block);
    }
    _blocks.clear();
  }
}

/// A registration that only records what happens to it
class _FakeAnnouncement implements DnsSdAnnouncement {
  _FakeAnnouncement(this.interfaceIndex, this.address);

  final int interfaceIndex;
  final String address;
  var stopped = false;

  @override
  Future<void> stop() async => stopped = true;
}

void main() {
  group('the structures of windns.h', () {
    test('have the sizes of the 64 bit C layout', () {
      expect(windowsDnsSdStructSizes, {
        'DNS_SERVICE_INSTANCE': 72,
        'DNS_SERVICE_CANCEL': 8,
        'DNS_SERVICE_BROWSE_REQUEST': 32,
        'DNS_SERVICE_RESOLVE_REQUEST': 32,
        'DNS_SERVICE_REGISTER_REQUEST': 48,
        'DNS_RECORDW header': 32,
      });
    });
  });

  group('what a browse callback hands over', () {
    final native = _Native();
    tearDown(native.free);

    test('the instances of its PTR records, with the TXT record of the same name', () {
      final list = native.ptr(
        '_smb._tcp.local',
        'My NAS._smb._tcp.local',
        next: native.txt('my nas._smb._tcp.local.', [
          'path=/photos',
          'u=me',
          'u=other',
          'flag',
          '=nokey',
        ], next: native.ptr('_smb._tcp.local', 'Gone._smb._tcp.local', ttl: 0)),
      );
      final records = readBrowseRecords(list.cast());
      expect(records.map((record) => (record.fullName, record.alive)), [
        ('My NAS._smb._tcp.local', true),
        ('Gone._smb._tcp.local', false),
      ]);
      expect(records.first.attributes, {'path': '/photos', 'u': 'me', 'flag': ''});
      expect(records.last.attributes, isEmpty);
    });

    test('an empty list tells nothing', () {
      expect(readBrowseRecords(nullptr), isEmpty);
    });
  });

  group('what a resolution hands over', () {
    final native = _Native();
    tearDown(native.free);

    test('the IPv4 address is the host, with the port and the properties', () {
      final instance = native.instance(
        fullName: 'Immuch360 on PIXEL._webdav._tcp.local.',
        host: 'pixel.local.',
        ip4: [192, 168, 1, 20],
        port: 8360,
        properties: {'app': 'immuch360', 'u': 'share'},
      );
      final service = serviceOfInstance(instance.cast(), '_webdav._tcp')!;
      expect(service.name, 'Immuch360 on PIXEL');
      expect(service.type, '_webdav._tcp');
      expect(service.host, '192.168.1.20');
      expect(service.port, 8360);
      expect(service.attributes, {'app': 'immuch360', 'u': 'share'});
    });

    test('without an address the host name serves, and the TXT record of the browse when it has no property', () {
      final instance = native.instance(fullName: 'NAS._smb._tcp.local', host: 'nas.local.', port: 445);
      final service = serviceOfInstance(instance.cast(), '_smb._tcp', fallbackAttributes: const {'path': '/a'})!;
      expect(service.host, 'nas.local');
      expect(service.attributes, {'path': '/a'});
    });

    test('an empty IPv4 address gives way to the host name', () {
      final instance = native.instance(
        fullName: 'NAS._smb._tcp.local',
        host: 'nas.local.',
        ip4: [0, 0, 0, 0],
        port: 445,
      );
      expect(serviceOfInstance(instance.cast(), '_smb._tcp')!.host, 'nas.local');
      expect(
        serviceOfInstance(
          native.instance(fullName: 'A._smb._tcp.local', ip4: [0, 0, 0, 0], port: 445).cast(),
          '_smb._tcp',
        ),
        isNull,
      );
    });

    test('nothing without a port or a host', () {
      expect(
        serviceOfInstance(native.instance(fullName: 'A._smb._tcp.local', host: 'a.local', port: 0).cast(), '_smb._tcp'),
        isNull,
      );
      expect(serviceOfInstance(native.instance(fullName: 'A._smb._tcp.local', port: 445).cast(), '_smb._tcp'), isNull);
      expect(serviceOfInstance(nullptr, '_smb._tcp'), isNull);
    });
  });

  group('instance names', () {
    test('the label before the type, its escapes read', () {
      expect(dnsSdInstanceName('My NAS._smb._tcp.local', '_smb._tcp'), 'My NAS');
      expect(dnsSdInstanceName('My NAS._SMB._tcp.local.', '_smb._tcp'), 'My NAS');
      expect(dnsSdInstanceName(r'jean\.s share._webdav._tcp.local', '_webdav._tcp'), 'jean.s share');
      expect(dnsSdInstanceName(r'Caf\195\169 photos._smb._tcp.local', '_smb._tcp'), 'Café photos');
      expect(dnsSdInstanceName(r'a\\b._smb._tcp.local', '_smb._tcp'), r'a\b');
      expect(dnsSdInstanceName('Other._http._tcp.local', '_smb._tcp'), 'Other');
    });

    test('a label is escaped for a full name', () {
      expect(dnsSdEscapeLabel('Immuch360 on jean.pc'), r'Immuch360 on jean\.pc');
      expect(dnsSdEscapeLabel(r'a\b'), r'a\\b');
      expect(dnsSdInstanceName('${dnsSdEscapeLabel('x.y')}._webdav._tcp.local', '_webdav._tcp'), 'x.y');
    });

    test('TXT strings', () {
      expect(txtAttributes(['a=1', 'b=', 'c', 'a=2', '=x', 'd=e=f']), {'a': '1', 'b': '', 'c': '', 'd': 'e=f'});
    });
  });

  group('the announcement of the computer share', () {
    late (int, String)? served;
    late List<_FakeAnnouncement> registered;
    late bool refuse;

    WindowsShareAnnouncer announcer() => WindowsShareAnnouncer(
      name: 'Immuch360 on PC',
      port: 8360,
      attributes: const {'app': 'immuch360'},
      servedInterface: () async => served,
      register:
          ({
            required name,
            required type,
            required port,
            required attributes,
            required interfaceIndex,
            required address,
          }) {
            expect((name, type, port), ('Immuch360 on PC', '_webdav._tcp', 8360));
            expect(attributes, {'app': 'immuch360'});
            if (refuse) {
              return null;
            }
            final announcement = _FakeAnnouncement(interfaceIndex, address);
            registered.add(announcement);
            return announcement;
          },
      refreshEvery: const Duration(seconds: 5),
    );

    setUp(() {
      served = (7, '192.168.1.42');
      registered = [];
      refuse = false;
    });

    test('is made on the interface the share listens on, with its address, and follows it', () async {
      final subject = announcer();
      await subject.start();
      expect(subject.announcedOn, (7, '192.168.1.42'));
      expect(registered.single.address, '192.168.1.42');

      // The laptop moves from the Wi-Fi to the Ethernet: the old announcement goes before the new one comes
      served = (12, '10.0.0.5');
      await subject.refresh();
      expect(registered.map((announcement) => (announcement.interfaceIndex, announcement.stopped)), [
        (7, true),
        (12, false),
      ]);

      await subject.stop();
      expect(registered.every((announcement) => announcement.stopped), isTrue);
      expect(subject.announcedOn, isNull);
    });

    test('is withdrawn while the share listens on no network, and made again when it does', () async {
      final subject = announcer();
      await subject.start();
      // Only a public network now, which the share leaves out
      served = null;
      await subject.refresh();
      expect(registered.single.stopped, isTrue);
      expect(subject.announcedOn, isNull);

      served = (7, '192.168.1.42');
      await subject.refresh();
      expect(registered, hasLength(2));
      expect(registered.last.stopped, isFalse);
      await subject.stop();
    });

    test('nothing is announced while no network is served', () async {
      served = null;
      final subject = announcer();
      await subject.start();
      expect(registered, isEmpty);
      await subject.stop();
    });

    test('a refused registration is tried again when the network changes, not every few seconds', () async {
      refuse = true;
      final subject = announcer();
      await subject.start();
      await subject.refresh();
      expect(registered, isEmpty);
      refuse = false;
      await subject.refresh();
      expect(registered, isEmpty);
      served = (8, '192.168.1.43');
      await subject.refresh();
      expect(registered.single.interfaceIndex, 8);
      await subject.stop();
    });

    test('follows a change of network as soon as the system reports it', () async {
      final changes = StreamController<void>();
      final subject = WindowsShareAnnouncer(
        name: 'Immuch360 on PC',
        port: 8360,
        attributes: const {'app': 'immuch360'},
        servedInterface: () async => served,
        register:
            ({
              required name,
              required type,
              required port,
              required attributes,
              required interfaceIndex,
              required address,
            }) {
              final announcement = _FakeAnnouncement(interfaceIndex, address);
              registered.add(announcement);
              return announcement;
            },
        // Far beyond the test: only the reported change can move the announcement
        refreshEvery: const Duration(hours: 1),
        networkChanges: changes.stream,
      );
      await subject.start();
      expect(subject.announcedOn, (7, '192.168.1.42'));

      // The laptop wakes up on a café's Wi-Fi, which the share leaves out
      served = null;
      changes.add(null);
      await pumpEventQueue();
      expect(registered.single.stopped, isTrue);
      expect(subject.announcedOn, isNull);

      await subject.stop();
      expect(changes.hasListener, isFalse);
      await changes.close();
    });

    test('nothing is registered once stopped', () async {
      final subject = announcer();
      await subject.start();
      await subject.stop();
      served = (9, '192.168.1.44');
      await subject.refresh();
      expect(registered, hasLength(1));
    });
  });

  group('on Windows the app never calls bonsoir', () {
    const bonsoir = MethodChannel('fr.skyost.bonsoir');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(bonsoir, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(bonsoir, null);
    });

    test('for the discovery', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final services = await bonsoirBrowse(
        '_smb._tcp',
        Future<void>.delayed(const Duration(milliseconds: 200)),
      ).toList().timeout(const Duration(seconds: 10));
      // dnsapi.dll answers on Windows only: elsewhere the stream ends empty
      if (!Platform.isWindows) {
        expect(services, isEmpty);
      }
      expect(calls, isEmpty);
    });

    test('a phone still does', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await bonsoirBrowse(
        '_smb._tcp',
        Future<void>.delayed(const Duration(milliseconds: 200)),
      ).toList().timeout(const Duration(seconds: 10));
      expect(calls, isNotEmpty);
    });

    test('for the announcement of the share', () {
      for (final (platform, advertise) in [
        (TargetPlatform.windows, windowsShareAdvertise),
        (TargetPlatform.android, bonsoirAdvertise),
        (TargetPlatform.iOS, bonsoirAdvertise),
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        final container = ProviderContainer();
        expect(container.read(phoneShareEnvironmentProvider).advertise, advertise, reason: platform.name);
        container.dispose();
      }
    });
  });

  // dnsapi itself, on a real Windows (the owner's PC through the wrapper, the Windows CI runner). The test service
  // has a type of its own, so that nothing on the network takes it for a share.
  group('on a real Windows', () {
    const type = '_imtest._tcp';

    Future<void> settled() async {
      for (var i = 0; i < 50 && windowsDnsSdPending > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    test('a browse starts, ends when asked, and dnsapi lets go of its memory', () async {
      final services = await windowsDnsSdBrowse(
        type,
        Future<void>.delayed(const Duration(seconds: 2)),
      ).toList().timeout(const Duration(seconds: 10));
      expect(services, isEmpty);
      await settled();
      expect(windowsDnsSdPending, 0);
    }, skip: !Platform.isWindows);

    // What crashed bonsoir_windows: answers of several services on dnsapi threads while browses start and stop. The
    // services found are not looked at, only that every request ends and its memory goes.
    test('browses of the real service types started and stopped over each other all end', () async {
      const types = ['_smb._tcp', '_webdav._tcp', '_http._tcp', '_googlecast._tcp', '_ipp._tcp', '_raop._tcp'];
      final runs = <Future<List<MdnsService>>>[];
      for (var round = 0; round < 4; round++) {
        for (final (index, type) in types.indexed) {
          runs.add(
            windowsDnsSdBrowse(
              type,
              Future<void>.delayed(Duration(milliseconds: 300 + 400 * index + 150 * round)),
            ).toList().timeout(const Duration(seconds: 20)),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      // A listener cancelled at once, before any answer
      await windowsDnsSdBrowse(types.first, Future<void>.delayed(const Duration(seconds: 5))).listen((_) {}).cancel();
      await Future.wait(runs);
      for (var i = 0; i < 100 && windowsDnsSdPending > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(windowsDnsSdPending, 0);
    }, skip: !Platform.isWindows);

    Future<(NetworkInterface, String)> lanInterface() async {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final lan = interfaces.where((interface) => interface.addresses.any((address) => !address.isLoopback)).first;
      return (lan, lan.addresses.firstWhere((address) => !address.isLoopback).address);
    }

    test('a registration on one interface is found by a browse, resolved, and withdrawn', () async {
      final (lan, address) = await lanInterface();
      final name = 'Immuch360 test ${Random().nextInt(1 << 30)}';
      final announcement = registerWindowsDnsSd(
        name: name,
        type: type,
        port: 8361,
        attributes: const {'app': 'test', 'v': '1'},
        interfaceIndex: lan.index,
        address: address,
      );
      expect(announcement, isNotNull);
      try {
        // Probing a new name takes about a second on mDNS
        await Future<void>.delayed(const Duration(seconds: 2));
        final found = await windowsDnsSdBrowse(
          type,
          Future<void>.delayed(const Duration(seconds: 6)),
        ).where((service) => service.name == name).toList().timeout(const Duration(seconds: 15));
        expect(found, isNotEmpty);
        expect(found.first.port, 8361);
        expect(found.first.attributes, {'app': 'test', 'v': '1'});
        expect(InternetAddress.tryParse(found.first.host), isNotNull);
      } finally {
        await announcement!.stop();
      }
      await settled();
      expect(windowsDnsSdPending, 0);
    }, skip: !Platform.isWindows);

    // dnsapi never calls back for a registration cancelled while pending, and keeps announcing one cancelled once
    // registered: the share stopped right after it started must still end with nothing announced and nothing kept
    test('a registration stopped while it registers is withdrawn once registered, and nothing stays', () async {
      final (lan, address) = await lanInterface();
      final name = 'Immuch360 test ${Random().nextInt(1 << 30)}';
      final announcement = registerWindowsDnsSd(
        name: name,
        type: type,
        port: 8362,
        attributes: const {'app': 'test'},
        interfaceIndex: lan.index,
        address: address,
      );
      expect(announcement, isNotNull);
      final stopping = Stopwatch()..start();
      await announcement!.stop();
      expect(stopping.elapsed, lessThan(const Duration(seconds: 4)));
      await settled();
      expect(windowsDnsSdPending, 0);
    }, skip: !Platform.isWindows);
  });
}
