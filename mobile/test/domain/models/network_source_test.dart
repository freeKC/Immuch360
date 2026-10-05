// The files of a share the app shows, and the content type the media bridge serves them with: the raw videos of 360°
// cameras are MP4 files under names of their own, which the players only read as video/mp4.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';

NetworkEntry _file(String name, {String? mimeType}) =>
    NetworkEntry(sourceId: 'nas', path: '/DCIM/$name', isDirectory: false, mimeType: mimeType);

void main() {
  test('takes the raw videos of Insta360, GoPro and DJI cameras for videos, and the .36p of the MAX 2 for a photo', () {
    for (final name in ['VID_00_001.insv', 'GS010013.360', 'CAM_20250715191201_0003_D.OSV']) {
      expect(_file(name).isVideo, isTrue, reason: name);
      expect(_file(name).isMedia, isTrue, reason: name);
    }
    expect(_file('GS__0001.36P').isImage, isTrue);
    expect(_file('IMG_00_001.insp').isImage, isTrue);
  });

  test('leaves out the low resolution proxies', () {
    for (final name in ['LRV_20240908_193126_11_004.lrv', 'GL010013.LRF']) {
      expect(_file(name).isMedia, isFalse, reason: name);
    }
  });

  test('serves the MP4 files of 360° cameras as video/mp4, whatever the server says', () {
    for (final name in ['VID_00_001.insv', 'GS010013.360', 'CAM_0003_D.OSV', 'LRV_0001.lrv', 'GL010013.LRF']) {
      expect(_file(name).guessedMimeType, 'video/mp4', reason: name);
      expect(_file(name, mimeType: 'application/x-360').guessedMimeType, 'video/mp4', reason: name);
    }
    expect(_file('GS__0001.36P').guessedMimeType, 'image/jpeg');
    expect(_file('IMG_00_001.insp').guessedMimeType, 'image/jpeg');
    // Other files keep the type of the server
    expect(_file('clip.mp4', mimeType: 'video/quicktime').guessedMimeType, 'video/quicktime');
    expect(_file('clip.mp4', mimeType: 'application/octet-stream').guessedMimeType, 'video/mp4');
  });
}
