import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/drone_import_grouping.dart';

NetworkEntry _file(String path, {DateTime? modified, int size = 10}) =>
    NetworkEntry(sourceId: 'tree:drone', path: path, isDirectory: false, size: size, modified: modified);

void main() {
  test('djiNameTime and djiSequenceNumber read DJI names', () {
    expect(djiNameTime('DJI_20261021143000_0001_D.JPG'), DateTime(2026, 10, 21, 14, 30));
    expect(djiNameTime('dji_20261021143000_0001_d.mp4'), DateTime(2026, 10, 21, 14, 30));
    expect(djiNameTime('DJI_0042.JPG'), isNull);
    expect(djiNameTime('DJI_20261341143000_0001_D.JPG'), isNull, reason: 'no 13th month');
    expect(djiNameTime('IMG_20261021_143000.jpg'), isNull);
    expect(djiSequenceNumber('DJI_20261021150000_0042_D.JPG'), 42);
    expect(djiSequenceNumber('DJI_0042.JPG'), 42);
    expect(djiSequenceNumber('GX010042.MP4'), isNull);
  });

  test('attaches the proxy, the flight data and the sound of a video by its name, case aside, and lists none', () {
    final listing = groupDroneFiles([
      _file('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4'),
      _file('/DCIM/DJI_001/DJI_20261021143100_0002_D.LRF'),
      _file('/DCIM/DJI_001/dji_20261021143100_0002_d.srt'),
      _file('/DCIM/DJI_001/DJI_20261021143100_0002_D.m4a'),
      _file('/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG'),
      // The flight data of another video, in another folder
      _file('/DCIM/DJI_002/DJI_20261021143100_0002_D.SRT'),
      _file('/DCIM/DJI_001/notes.txt'),
    ]);

    expect(listing.allMedia.map((entry) => entry.name), [
      'DJI_20261021143100_0002_D.MP4',
      'DJI_20261021143000_0001_D.JPG',
    ]);
    final video = listing.days.single.media.first;
    expect(video.proxy?.name, 'DJI_20261021143100_0002_D.LRF');
    expect(video.flightData?.name, 'dji_20261021143100_0002_d.srt');
    expect(video.soundApart?.name, 'DJI_20261021143100_0002_D.m4a');
    final photo = listing.days.single.media.last;
    expect(photo.proxy, isNull);
    expect(photo.flightData, isNull);
  });

  test('groups by day, the newest first, from the DJI name else the file date', () {
    final listing = groupDroneFiles([
      _file('/DCIM/DJI_001/DJI_20261020100000_0001_D.JPG'),
      _file('/DCIM/DJI_001/DJI_20261021090000_0002_D.JPG'),
      _file('/DCIM/DJI_001/DJI_20261021180000_0003_D.MP4'),
      _file('/DCIM/100GOPRO/GX010042.MP4', modified: DateTime(2026, 10, 19, 12)),
    ]);

    expect(listing.days.map((day) => day.day), [
      DateTime(2026, 10, 21),
      DateTime(2026, 10, 20),
      DateTime(2026, 10, 19),
    ]);
    expect(listing.days.first.media.map((media) => media.entry.name), [
      'DJI_20261021180000_0003_D.MP4',
      'DJI_20261021090000_0002_D.JPG',
    ]);
  });

  test('matches a PANORAMA folder with the sphere of its sequence number taken after it', () {
    final listing = groupDroneFiles([
      for (var i = 1; i <= 5; i++) _file('/DCIM/PANORAMA/001_0042/DJI_2026102114590${i}_000${i}_D.JPG'),
      _file('/DCIM/DJI_001/DJI_20261021150000_0042_D.JPG'),
      // Another photo of the same day
      _file('/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG'),
    ]);

    final day = listing.days.single;
    expect(day.media.map((media) => media.entry.name), [
      'DJI_20261021150000_0042_D.JPG',
      'DJI_20261021143000_0001_D.JPG',
    ]);
    expect(day.media.first.sphereSources, hasLength(5));
    expect(day.unstitched, isEmpty);
    expect(listing.allMedia, hasLength(7));
  });

  test('a PANORAMA folder without its sphere, or with a sphere taken long after, is shown not stitched', () {
    final listing = groupDroneFiles([
      for (var i = 1; i <= 3; i++) _file('/DCIM/PANORAMA/001_0007/DJI_2026102110000${i}_000${i}_D.JPG'),
      for (var i = 1; i <= 3; i++) _file('/DCIM/PANORAMA/002_0008/DJI_2026102111000${i}_000${i}_D.JPG'),
      // The sphere of 0008 an hour later: not its sphere
      _file('/DCIM/DJI_001/DJI_20261021120000_0008_D.JPG'),
    ]);

    final day = listing.days.single;
    expect(day.media.single.sphereSources, isEmpty);
    expect(day.unstitched.map((group) => group.folder), ['/DCIM/PANORAMA/002_0008', '/DCIM/PANORAMA/001_0007']);
    expect(day.unstitched.first.sources, hasLength(3));
  });

  test('GoPro proxies and thumbnails are attached, chapters stay apart; Insta360 proxies are hidden', () {
    final listing = groupDroneFiles([
      _file('/DCIM/100GOPRO/GX010042.MP4', modified: DateTime(2026, 10, 21, 10)),
      _file('/DCIM/100GOPRO/GX020042.MP4', modified: DateTime(2026, 10, 21, 10, 8)),
      _file('/DCIM/100GOPRO/GL010042.LRV'),
      _file('/DCIM/100GOPRO/GX010042.THM'),
      _file('/DCIM/Camera01/VID_20261021_100000_00_001.insv', modified: DateTime(2026, 10, 21, 9)),
      _file('/DCIM/Camera01/LRV_20261021_100000_01_001.lrv'),
    ]);

    final media = listing.days.single.media;
    expect(media.map((item) => item.entry.name), ['GX020042.MP4', 'GX010042.MP4', 'VID_20261021_100000_00_001.insv']);
    expect(media[1].proxy?.name, 'GL010042.LRV');
    expect(media[1].cameraThumbnail?.name, 'GX010042.THM');
    expect(media[0].proxy, isNull);
  });

  test('"Select all new" leaves out what was sent, the sphere sources and the files the server refuses', () {
    final listing = groupDroneFiles([
      for (var i = 1; i <= 2; i++) _file('/DCIM/PANORAMA/001_0042/DJI_2026102114590${i}_000${i}_D.JPG'),
      _file('/DCIM/DJI_001/DJI_20261021150000_0042_D.JPG'),
      _file('/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG'),
      _file('/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4'),
      _file('/DCIM/DJI_001/CAM_20261021143200_0003_D.OSV'),
    ]);

    final selected = droneNewFiles(listing, (entry) => entry.name.contains('_0001_'));

    expect(selected.map((entry) => entry.name), ['DJI_20261021150000_0042_D.JPG', 'DJI_20261021143100_0002_D.MP4']);
    expect(listing.byPath['/DCIM/DJI_001/CAM_20261021143200_0003_D.OSV']?.isRefused, isTrue);
  });
}
