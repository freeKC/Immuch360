// The kiosk mode of the Meta Quest: the media it opens at the start of the app as the setting keeps it, the switch
// and the end card text in the settings, and the options the immersive viewer is told.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/kiosk_config.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';

RemoteAsset _film({String? localId}) => RemoteAsset(
  id: 'remote-1',
  localId: localId,
  name: 'expo_360.mp4',
  ownerId: 'owner',
  checksum: 'c1',
  type: AssetType.video,
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
  isEdited: false,
);

LocalAsset _devicePhoto() => LocalAsset(
  id: 'local-7',
  name: 'PANO_0001.jpg',
  type: AssetType.image,
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  group('KioskMedia', () {
    test('a server film keeps both of its ids, its name and that it is a video', () {
      final media = KioskMedia.asset(_film(localId: 'local-2'));

      expect(media, isA<KioskAssetMedia>());
      final asset = media as KioskAssetMedia;
      expect(asset.remoteId, 'remote-1');
      expect(asset.localId, 'local-2');
      expect(asset.name, 'expo_360.mp4');
      expect(asset.isVideo, isTrue);
    });

    test('an asset reads back as it was kept', () {
      final decoded = KioskMedia.decode(KioskMedia.asset(_film(localId: 'local-2')).encode());

      expect(decoded, KioskMedia.asset(_film(localId: 'local-2')));
    });

    test('a photo only on the device keeps its device id alone', () {
      final media = KioskMedia.asset(_devicePhoto()) as KioskAssetMedia;

      expect(media.remoteId, isNull);
      expect(media.localId, 'local-7');
      expect(media.isVideo, isFalse);
      expect(KioskMedia.decode(media.encode()), media);
    });

    test('a file of a network share keeps its share and its path', () {
      const file = NetworkPanoramaFile(sourceId: 'nas', path: '/Expo/salle 2/visite.mp4', size: 42);
      final media = KioskMedia.shareFile(file);

      expect(media, isA<KioskShareFile>());
      final share = media as KioskShareFile;
      expect(share.sourceId, 'nas');
      expect(share.path, '/Expo/salle 2/visite.mp4');
      expect(share.name, 'visite.mp4');
      expect(share.isVideo, isTrue);
      expect(share.size, 42);
      expect(KioskMedia.decode(media.encode()), media);
    });

    test('the stored JSON names its kind', () {
      expect(jsonDecode(KioskMedia.asset(_film()).encode()), {
        'type': 'asset',
        'remoteId': 'remote-1',
        'name': 'expo_360.mp4',
        'isVideo': true,
      });
      expect(
        jsonDecode(KioskMedia.shareFile(const NetworkPanoramaFile(sourceId: 'nas', path: '/a.jpg')).encode()),
        {'type': 'share', 'sourceId': 'nas', 'path': '/a.jpg', 'name': 'a.jpg', 'isVideo': false},
      );
    });

    test('nothing stored, or a value that does not read, is no media', () {
      for (final json in [
        null,
        '',
        'not json',
        '[]',
        '{"type":"asset","name":"a.mp4","isVideo":true}',
        '{"type":"share","sourceId":"nas","name":"a.mp4","isVideo":true}',
        '{"type":"share","sourceId":"nas","path":"a.mp4","name":"a.mp4","isVideo":true}',
        '{"type":"album","name":"a.mp4","isVideo":true}',
        '{"type":"asset","remoteId":"r","isVideo":true}',
        '{"type":"asset","remoteId":"r","name":"a.mp4"}',
      ]) {
        expect(KioskMedia.decode(json), isNull, reason: '$json');
      }
    });
  });

  group('Kiosk mode (experimental)', () {
    test('is on by default, with nothing chosen: the app starts as usual', () {
      expect(const AppConfig().kiosk.enabled, isTrue);
      expect(defaultConfig.read(SettingsKey.kioskEnabled), isTrue);
      expect(defaultConfig.read(SettingsKey.kioskMedia), isNull);
      expect(defaultConfig.read(SettingsKey.kioskEndText), isNull);
      expect(const KioskConfig().chosenMedia, isNull);
      expect(const KioskConfig().isActive, isFalse);
    });

    test('a media chosen makes the next start a kiosk, the switch off does not', () {
      final media = KioskMedia.asset(_film()).encode();
      final config = AppConfig.fromEntries({SettingsKey.kioskMedia: media});

      expect(config.kiosk.chosenMedia, KioskMedia.asset(_film()));
      expect(config.kiosk.isActive, isTrue);
      expect(config.write(SettingsKey.kioskEnabled, false).kiosk.isActive, isFalse);
      expect(config.write(SettingsKey.kioskMedia, null).kiosk.isActive, isFalse);
    });

    test('a stored media that no longer reads makes no kiosk', () {
      expect(AppConfig.fromEntries({SettingsKey.kioskMedia: '{"type":"album"}'}).kiosk.isActive, isFalse);
    });

    test('the end card text is the one typed, else the default the app translates', () {
      final config = AppConfig.fromEntries({SettingsKey.kioskEndText: 'Dziękujemy za wspólną podróż'});

      expect(config.read(SettingsKey.kioskEndText), 'Dziękujemy za wspólną podróż');
      expect(config.kiosk.endTextOr('Thank you for the journey'), 'Dziękujemy za wspólną podróż');
      expect(const KioskConfig().endTextOr('Thank you for the journey'), 'Thank you for the journey');
      expect(const KioskConfig(endText: '   ').endTextOr('Thank you for the journey'), 'Thank you for the journey');
      expect(config.write(SettingsKey.kioskEndText, null).kiosk.endText, isNull);
    });
  });

  group('KioskOptions', () {
    test('the viewer is told the end card text and the exit notice', () {
      const options = KioskOptions(endText: 'Merci pour le voyage', exitHint: 'Maintenez B ou Y une seconde');

      expect(jsonDecode(options.toJson()), {
        'endText': 'Merci pour le voyage',
        'exitHint': 'Maintenez B ou Y une seconde',
      });
    });
  });
}
