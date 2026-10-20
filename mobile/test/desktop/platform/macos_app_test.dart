// What the macOS app declares and how it keeps its secrets: the local network keys of macOS 15 cover every Bonjour
// type the app browses, and the secure storage stays out of the data protection keychain, which the builds signed for
// the computer that runs them cannot use, while the other systems keep the plugin's defaults.

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';

/// The text of a string key of the Info.plist, null when absent
String? _string(String plist, String key) =>
    RegExp('<key>$key</key>\\s*<string>([^<]*)</string>').firstMatch(plist)?.group(1);

List<String>? _strings(String plist, String key) {
  final array = RegExp('<key>$key</key>\\s*<array>(.*?)</array>', dotAll: true).firstMatch(plist)?.group(1);
  return array == null ? null : [for (final match in RegExp('<string>([^<]*)</string>').allMatches(array)) match[1]!];
}

void main() {
  final plistFile = File('macos/Runner/Info.plist');

  group('Info.plist', () {
    late String plist;

    setUpAll(() => plist = plistFile.readAsStringSync());

    test('says why the app uses the local network', () {
      expect(_string(plist, 'NSLocalNetworkUsageDescription'), isNotNull);
      expect(_string(plist, 'NSLocalNetworkUsageDescription')!.length, greaterThan(40));
    });

    test('lists every Bonjour type the app browses, and the one of the phone shares', () {
      final services = _strings(plist, 'NSBonjourServices');
      expect(services, isNotNull);
      expect(services, containsAll({...MdnsProbe.serviceTypes, phoneShareServiceType}));
      for (final service in services!) {
        expect(service, matches(RegExp(r'^_[a-z0-9-]+\._(tcp|udp)$')));
      }
    });

    test('says why for the protected folders a library folder or a download may be in', () {
      for (final key in [
        'NSDesktopFolderUsageDescription',
        'NSDocumentsFolderUsageDescription',
        'NSDownloadsFolderUsageDescription',
        'NSRemovableVolumesUsageDescription',
        'NSNetworkVolumesUsageDescription',
      ]) {
        expect(_string(plist, key), isNotNull, reason: key);
      }
    });
  }, skip: plistFile.existsSync() ? false : 'run from mobile/');

  group('secure storage', () {
    const defaults = FlutterSecureStorage();
    const storage = SecureStorageRepository.storage;

    test('macOS: the login keychain, not the data protection keychain', () {
      expect(storage.mOptions.params['useDataProtectionKeyChain'], 'false');
      expect(defaults.mOptions.params['useDataProtectionKeyChain'], 'true', reason: 'the default this works around');
      // Every other macOS option as the plugin's default: the same items as before for the same key
      expect(
        {...storage.mOptions.params}..remove('useDataProtectionKeyChain'),
        {...defaults.mOptions.params}..remove('useDataProtectionKeyChain'),
      );
    });

    test('the other systems keep the defaults of the plugin', () {
      expect(storage.aOptions.params, defaults.aOptions.params);
      expect(storage.iOptions.params, defaults.iOptions.params);
      expect(storage.lOptions.params, defaults.lOptions.params);
      expect(storage.wOptions.params, defaults.wOptions.params);
    });
  });
}
