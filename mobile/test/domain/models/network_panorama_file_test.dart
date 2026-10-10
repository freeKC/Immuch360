// The 360° files of the shares as the 360° list keeps them: stored and read back, added when found, replaced when the
// file changed, taken out when no longer 360°, at most a number of them, newest first.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';
import 'package:immich_mobile/domain/models/network_source.dart';

NetworkEntry _entry(String path, {String sourceId = 'nas', int? size = 1000, DateTime? modified}) => NetworkEntry(
  sourceId: sourceId,
  path: path,
  isDirectory: false,
  size: size,
  modified: modified ?? DateTime.utc(2026, 10, 1),
);

void main() {
  group('NetworkPanoramaFile', () {
    test('is stored and read back', () {
      final files = [
        NetworkPanoramaFile.of(_entry('/pano.jpg', modified: DateTime.utc(2026, 10, 5, 8))),
        NetworkPanoramaFile.of(_entry('/clip.insv', size: null, modified: null)),
      ];

      final read = NetworkPanoramaFile.decodeList(NetworkPanoramaFile.encodeList(files));

      expect(read, files);
      expect(read.first.modified!.isAtSameMomentAs(DateTime.utc(2026, 10, 5, 8)), isTrue);
      expect(read.last.isVideo, isTrue);
    });

    test('a damaged value reads as nothing, a damaged item is left out', () {
      expect(NetworkPanoramaFile.decodeList('not json'), isEmpty);
      expect(NetworkPanoramaFile.decodeList('{"sourceId": "nas"}'), isEmpty);
      expect(
        NetworkPanoramaFile.decodeList(
          '[{"sourceId": "nas", "path": "/a.jpg"}, {"sourceId": "nas", "path": "relative.jpg"}, 3, {"path": "/b.jpg"}]',
        ),
        [const NetworkPanoramaFile(sourceId: 'nas', path: '/a.jpg')],
      );
    });
  });

  group('withNetworkPanorama', () {
    test('adds a 360° file last, and leaves the list as it is when it knows it already', () {
      final once = withNetworkPanorama(const [], _entry('/a.jpg'), is360: true);
      final twice = withNetworkPanorama(once, _entry('/b.jpg'), is360: true);

      expect(twice.map((file) => file.path), ['/a.jpg', '/b.jpg']);
      expect(withNetworkPanorama(twice, _entry('/a.jpg'), is360: true), same(twice));
    });

    test('a file changed since replaces its record, last', () {
      final files = withNetworkPanorama(
        withNetworkPanorama(const [], _entry('/a.jpg'), is360: true),
        _entry('/b.jpg'),
        is360: true,
      );

      final changed = withNetworkPanorama(files, _entry('/a.jpg', size: 2000), is360: true);

      expect(changed.map((file) => (file.path, file.size)), [('/b.jpg', 1000), ('/a.jpg', 2000)]);
    });

    test('takes out a file no longer 360°, and ignores a flat file it does not know or what is no media', () {
      final files = withNetworkPanorama(const [], _entry('/a.jpg'), is360: true);

      expect(withNetworkPanorama(files, _entry('/a.jpg'), is360: false), isEmpty);
      expect(withNetworkPanorama(files, _entry('/flat.jpg'), is360: false), same(files));
      expect(withNetworkPanorama(files, _entry('/notes.txt'), is360: true), same(files));
      expect(
        withNetworkPanorama(files, _entry('/a.jpg', sourceId: 'other'), is360: true).map((file) => file.sourceId),
        ['nas', 'other'],
        reason: 'the same path on another share is another file',
      );
    });

    test('keeps the files found last when there are too many', () {
      var files = const <NetworkPanoramaFile>[];
      for (var i = 0; i < 5; i++) {
        files = withNetworkPanorama(files, _entry('/$i.jpg'), is360: true, maxFiles: 3);
      }

      expect(files.map((file) => file.path), ['/2.jpg', '/3.jpg', '/4.jpg']);
    });
  });

  test('newestNetworkPanoramasFirst: by the date of the file, those without one last, latest found first', () {
    final files = [
      NetworkPanoramaFile(sourceId: 'nas', path: '/old.jpg', modified: DateTime.utc(2024)),
      const NetworkPanoramaFile(sourceId: 'nas', path: '/undated1.jpg'),
      NetworkPanoramaFile(sourceId: 'nas', path: '/new.jpg', modified: DateTime.utc(2026)),
      const NetworkPanoramaFile(sourceId: 'nas', path: '/undated2.jpg'),
    ];

    expect(newestNetworkPanoramasFirst(files).map((file) => file.path), [
      '/new.jpg',
      '/old.jpg',
      '/undated2.jpg',
      '/undated1.jpg',
    ]);
  });
}
