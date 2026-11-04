import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';

import 'splat_photo_fixtures.dart';

/// The packet of the splat photos (plan of 3 November 2026, section 2.3) and their names (section 2.4)
void main() {
  const sum = '7d0a8386d76ba71739422192810eae63320c989c52523a97697e9f7413d118d5';
  const packet = SplatPhotoXmp(
    splatVersion: 2,
    splatGaussians: 150000,
    splatShDegree: 3,
    splatLength: 3612448,
    splatSha256: sum,
    splatName: 'salon_splat.spz',
    splatSourceSha256: sum,
    splatUp: 'yDown',
    splatPoster: SplatPosterKind.view,
    created: '2026-11-03T16:53:00+01:00',
    creatorTool: 'Immuch360 3.3.0 (windows)',
    description: 'Splat scene of 150,000 gaussians. Open it with Immuch360 to explore it.',
  );

  group('the packet', () {
    test('reads back what it wrote, FormatVersion 1 and Kind GaussianSplat', () {
      final xml = packet.toXml();
      expect(xml, contains('Immuch360:FormatVersion="1"'));
      expect(xml, contains('Immuch360:Kind="GaussianSplat"'));
      expect(SplatPhotoXmp.parse(xml), packet);
    });

    test('ends with 4 KiB of whitespace before the end of the packet, in lines of 100', () {
      final xml = packet.toXml();
      final end = xml.indexOf('<?xpacket end="w"?>');
      final padding = xml.substring(end - splatPhotoPadding, end);
      expect(padding.trim(), isEmpty);
      expect(padding.length, splatPhotoPadding);
      expect(padding.split('\n').first.length, 99);
      expect(xml.substring(0, end - splatPhotoPadding), endsWith('</x:xmpmeta>\n'));
    });

    test('never names a motion photo, a container, a panorama, MPF or an extended XMP', () {
      final xml = packet.toXml();
      for (final word in ['GCamera', 'Container', 'MotionPhoto', 'MicroVideo', 'GPano', 'MPF', 'HasExtendedXMP']) {
        expect(xml, isNot(contains(word)), reason: word);
      }
    });

    test('is complete, of this version, and gives the head of its SPZ for the gate', () {
      expect(packet.isComplete, isTrue);
      expect(packet.isNewer, isFalse);
      expect(packet.head, const SplatHead(format: SplatFormat.spz, formatVersion: 2, gaussians: 150000, shDegree: 3));
    });

    test('a newer FormatVersion, another payload or an SPZ past version 4 is made by a newer version', () {
      expect(
        SplatPhotoXmp.parse(packet.toXml().replaceFirst('FormatVersion="1"', 'FormatVersion="2"'))!.isNewer,
        isTrue,
      );
      expect(
        SplatPhotoXmp.parse(packet.toXml().replaceFirst('SplatFormat="spz"', 'SplatFormat="spz-2"'))!.isNewer,
        isTrue,
      );
      expect(SplatPhotoXmp.parse(packet.toXml().replaceFirst('SplatVersion="2"', 'SplatVersion="5"'))!.isNewer, isTrue);
      expect(SplatPhotoXmp.parse(packet.toXml().replaceFirst('SplatVersion="2"', 'SplatVersion="5"'))!.head, isNull);
    });

    test('a field missing or impossible is not complete, and gives no head', () {
      for (final broken in [
        packet.toXml().replaceFirst(RegExp(r'\s*Immuch360:SplatLength="\d+"'), ''),
        packet.toXml().replaceFirst('SplatLength="3612448"', 'SplatLength="12"'),
        packet.toXml().replaceFirst('SplatLength="3612448"', 'SplatLength="3000000000"'),
        packet.toXml().replaceFirst(sum, sum.toUpperCase()),
        packet.toXml().replaceFirst('SplatShDegree="3"', 'SplatShDegree="5"'),
        packet.toXml().replaceFirst('SplatName="salon_splat.spz"', 'SplatName=" "'),
        packet.toXml().replaceFirst(RegExp(r'\s*Immuch360:SplatFormat="spz"'), ''),
      ]) {
        final read = SplatPhotoXmp.parse(broken)!;
        expect(read.isComplete, isFalse, reason: broken);
        expect(read.head, isNull);
      }
    });

    test('is read under another prefix, and from elements (exiftool writes them so)', () {
      final other = packet.toXml().replaceAll('Immuch360:', 'I3:').replaceFirst('xmlns:Immuch360', 'xmlns:I3');
      expect(SplatPhotoXmp.parse(other)!.splatLength, 3612448);
      final edited = SplatPhotoXmp.findIn(splatPhotoFixture('ok_exiftool.jpg'))!;
      expect(edited.splatName, 'axes_v2.spz');
      expect(edited.splatLength, 913);
      expect(edited.description, 'Splat scene of 686 gaussians. Open it with Immuch360 to explore it.');
    });

    test('another Kind of ours is no splat photo', () {
      expect(
        SplatPhotoXmp.parse(packet.toXml().replaceFirst('Kind="GaussianSplat"', 'Kind="VolumetricScene"')),
        isNull,
      );
    });

    test('an unknown SplatUp or SplatPoster is dropped, the rest kept', () {
      final read = SplatPhotoXmp.parse(
        packet.toXml().replaceFirst('SplatUp="yDown"', 'SplatUp="sideways"').replaceFirst('"view"', '"photo"'),
      )!;
      expect(read.splatUp, isNull);
      expect(read.splatPoster, isNull);
      expect(read.isComplete, isTrue);
    });

    test('only a JPEG is read, and only its first 128 KiB', () {
      final xml = utf8.encode(packet.toXml());
      expect(SplatPhotoXmp.findIn(Uint8List.fromList([0xFF, 0xD8, ...xml])), packet);
      expect(SplatPhotoXmp.findIn(Uint8List.fromList([0x89, 0x50, ...xml])), isNull);
      expect(SplatPhotoXmp.findIn(splatPhotoFixture('png_with_packet.png')), isNull);
      final late = Uint8List(splatPhotoHeadBytes + xml.length)
        ..[0] = 0xFF
        ..[1] = 0xD8
        ..setAll(splatPhotoHeadBytes - 100, xml);
      expect(SplatPhotoXmp.findIn(late), isNull);
    });
  });

  group('the names', () {
    test('the word splat, in any case, between dots, underscores, dashes and spaces', () {
      for (final name in ['room_splat.jpg', 'Room-SPLAT.jpeg', 'splat.jpg', 'a splat b.jpg', 'x.splat.jpg']) {
        expect(isSplatPhotoCandidate(name), isTrue, reason: name);
      }
      for (final name in ['splats.jpg', 'gaussiansplat.jpg', 'room_scene3D.jpg', 'IMG_0001.jpg', 'splatter.jpg']) {
        expect(isSplatPhotoCandidate(name), isFalse, reason: name);
      }
    });

    test('<stem>_splat.jpg, a trailing _splat of the stem kept once', () {
      expect(splatPhotoNameFor('salon.spz'), 'salon_splat.jpg');
      expect(splatPhotoNameFor('salon_splat.spz'), 'salon_splat.jpg');
      expect(splatPhotoNameFor('Salon_SPLAT.ply'), 'Salon_splat.jpg');
      expect(splatPhotoNameFor('/mnt/nas/scenes/room.ply'), 'room_splat.jpg');
      expect(splatPhotoNameFor(r'C:\scenes\room 150k.spz'), 'room 150k_splat.jpg');
    });

    test('safe for every system', () {
      expect(splatPhotoNameFor('a:b*c?.spz'), 'a_b_c__splat.jpg');
      expect(splatPhotoNameFor('con.spz'), '_con_splat.jpg');
      expect(splatPhotoNameFor('.spz'), '.spz_splat.jpg');
      expect(splatPhotoNameFor('_splat.spz'), 'scene_splat.jpg');
      expect(splatPhotoNameFor('${'x' * 300}.spz').length, 180 + '_splat.jpg'.length);
      expect(isSplatPhotoCandidate(splatPhotoNameFor('anything.spz')), isTrue);
    });
  });
}
