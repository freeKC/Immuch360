import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// The packet of test/fixtures/ai_immersive/xmp_v1_sample.xmp, the example of the design
const _sample = StereoPhotoXmp(
  eyes: StereoEyes.full,
  eyeOrder: EyeOrder.leftRight,
  eyeWidth: 4000,
  eyeHeight: 3000,
  leftEye: LeftEyeSource.original,
  origin: ImmersiveOrigin.estimatedDepth,
  depthModel: 'depth-anything-v2-small',
  depthModelSha256: depthModelOnnxSha256,
  pipeline: 'relief-v1',
  parallax: 0.02,
  convergence: 0.5,
  derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000000',
  sourceName: 'salon.jpg',
  sourceSize: 4182311,
  sourceSha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=',
  sourceQuarterTurns: 0,
  created: '2026-10-27T10:12:00+01:00',
  creatorTool: 'Immuch360 Desktop 3.3.0 (windows)',
  description: stereoPhotoDescription,
);

void main() {
  final fixture = File('test/fixtures/ai_immersive/xmp_v1_sample.xmp').readAsStringSync();

  group('StereoPhotoXmp', () {
    test('writes the packet of the fixture, field for field', () {
      expect(_sample.toXml(), fixture);
    });

    test('reads every field of the fixture', () {
      final read = StereoPhotoXmp.parse(fixture);

      expect(read, _sample);
      expect(read!.isReadableStereoPhoto, isTrue);
      expect(read.isEstimatedRelief, isTrue);
      expect(read.isNewerFormat, isFalse);
    });

    test('the SHA-1 of the original is in base64, as the checksum column and Immich', () {
      final original = utf8.encode('Immuch360 sample original salon.jpg');
      final base64Sum = base64.encode(sha1.convert(original).bytes);

      expect(StereoPhotoXmp.parse(fixture)!.sourceSha1, base64Sum);
      expect(base64Sum, isNot(matches(RegExp(r'^[0-9a-f]{40}$'))));
    });

    test('a packet made by the app reads back the same, flags and awkward names included', () {
      final made = StereoPhotoXmp.estimated(
        eyeWidth: 5712,
        eyeHeight: 4284,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'Tom & "Léa" <été>.jpg',
        sourceSize: 12,
        sourceSha1: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        sourceQuarterTurns: 5,
        created: StereoPhotoXmp.xmpDateTime(DateTime.utc(2026, 10, 27, 9, 12)),
        creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
        qualityFlags: const [ReliefQualityFlag.dark, ReliefQualityFlag.lowRelief],
      );

      final read = StereoPhotoXmp.parse(made.toXml());

      expect(read, made);
      expect(read!.sourceName, 'Tom & "Léa" <été>.jpg');
      // Our reader would read the raw name back too: what other readers need is the escaped form
      expect(made.toXml(), contains('Immuch360:SourceName="Tom &amp; &quot;Léa&quot; &lt;été&gt;.jpg"'));
      expect(read.sourceQuarterTurns, 1);
      expect(read.qualityFlags, [ReliefQualityFlag.lowRelief, ReliefQualityFlag.dark]);
      expect(made.toXml(), contains('Immuch360:QualityFlags="lowRelief,dark"'));
      expect(read.derivativeId, matches(RegExp(r'^urn:uuid:[0-9a-f-]{36}$')));
      expect(read.created, '2026-10-27T09:12:00+00:00');
      expect(read.description, stereoPhotoDescription);
    });

    test('no value ends with = before its quote, which ExifTool reads as the start of another attribute', () {
      // ExifTool 13 reads Immuch360:SourceSha1="X8tY...xeM=" as an attribute named up to that last =, and loses
      // SourceSha1 and the attribute after it. Every SHA-1 in base64 ends with =: it is written as &#x3D;, the same
      // character for an XML reader.
      final made = StereoPhotoXmp.estimated(
        eyeWidth: 1,
        eyeHeight: 1,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'a=b=.jpg',
        sourceSize: 1,
        sourceSha1: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        sourceQuarterTurns: 1,
        created: '2026-10-27T10:12:00+01:00',
        creatorTool: 'Immuch360 Desktop',
      );

      final packet = made.toXml();

      final closingAfterEquals = RegExp(r'''=["']([ \t\r\n]|/?>)''');
      expect(packet, isNot(matches(closingAfterEquals)));
      expect(packet, contains('Immuch360:SourceSha1="AAAAAAAAAAAAAAAAAAAAAAAAAAA&#x3D;"'));
      final read = StereoPhotoXmp.parse(packet)!;
      expect(read.sourceSha1, 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=');
      expect(read.sourceName, 'a=b=.jpg');
      expect(read.sourceQuarterTurns, 1);
      expect(fixture, isNot(matches(closingAfterEquals)));
    });

    test('a control character of a file name is written as U+FFFD, which XML 1.0 can hold', () {
      // A Linux name may hold one. Raw, or even as a reference, it makes the packet invalid XML, which ExifTool or
      // Immich would refuse whole, the description included. Tab, line feed and carriage return are allowed.
      final made = StereoPhotoXmp.estimated(
        eyeWidth: 1,
        eyeHeight: 1,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'a\u0001b\u001F\tc.jpg',
        sourceSize: 1,
        sourceSha1: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        sourceQuarterTurns: 0,
        created: '2026-10-27T10:12:00+01:00',
        creatorTool: 'Immuch360 Desktop',
      );

      final packet = made.toXml();

      expect(packet, isNot(matches(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'))));
      expect(packet, contains('Immuch360:SourceName="a\uFFFDb\uFFFD&#x9;c.jpg"'));
      expect(StereoPhotoXmp.parse(packet)!.sourceName, 'a\uFFFDb\uFFFD\tc.jpg');
      expect(xmpSafeText('a\u0000b\nc\rd'), 'a\uFFFDb\nc\rd');
    });

    test('two packets made by the app have two derivative ids', () {
      StereoPhotoXmp make() => StereoPhotoXmp.estimated(
        eyeWidth: 1,
        eyeHeight: 1,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'a.jpg',
        sourceSize: 1,
        sourceSha1: 'x',
        sourceQuarterTurns: 0,
        created: '2026-10-27T10:12:00+01:00',
        creatorTool: 'Immuch360 Desktop',
      );

      expect(make().derivativeId, isNot(make().derivativeId));
    });

    test('a newer FormatVersion is still read, to be shown flat with its reason', () {
      final read = StereoPhotoXmp.parse(
        fixture.replaceFirst('Immuch360:FormatVersion="1"', 'Immuch360:FormatVersion="2"'),
      );

      expect(read!.formatVersion, 2);
      expect(read.isNewerFormat, isTrue);
      expect(read.isReadableStereoPhoto, isFalse);
      expect(read.sourceName, 'salon.jpg');
    });

    test('a Kind this build does not know gives no kind but is still ours', () {
      final read = StereoPhotoXmp.parse(fixture.replaceFirst('"StereoPhoto"', '"VolumetricHologram"'));

      expect(read, isNotNull);
      expect(read!.kind, isNull);
      expect(read.isReadableStereoPhoto, isFalse);
    });

    test('elements instead of attributes, another prefix and single quotes are read', () {
      const rewritten = '''
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about='' xmlns:im='http://ns.aprogsys.com/immuch360/1.0/' xmlns:tool="http://ns.adobe.com/xap/1.0/">
   <im:FormatVersion>1</im:FormatVersion>
   <im:Kind>StereoPhoto</im:Kind>
   <im:StereoLayout>SideBySideHalf</im:StereoLayout>
   <im:EyeOrder>RightLeft</im:EyeOrder>
   <im:SourceName>a &amp; b.jpg</im:SourceName>
   <im:Parallax> 0.02 </im:Parallax>
   <tool:CreatorTool>Immuch360 Desktop 3.3.0 (macos)</tool:CreatorTool>
   <im:QualityFlags>hiddenAreas unknownFlag</im:QualityFlags>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>''';

      final read = StereoPhotoXmp.parse(rewritten)!;

      expect(read.kind, ImmersiveKind.stereoPhoto);
      expect(read.eyes, StereoEyes.half);
      expect(read.eyeOrder, EyeOrder.rightLeft);
      expect(read.sourceName, 'a & b.jpg');
      expect(read.parallax, 0.02);
      expect(read.creatorTool, 'Immuch360 Desktop 3.3.0 (macos)');
      expect(read.qualityFlags, [ReliefQualityFlag.hiddenAreas]);
      expect(read.origin, isNull);
      expect(read.settingsKey, isNull);
    });

    test('an entity that names no character is left as written, and the rest of the packet is read', () {
      final damaged = fixture.replaceFirst('salon.jpg', '&#x110000;&#99999999999999999999999;&#x41;&#66;');
      final read = StereoPhotoXmp.parse(damaged)!;

      expect(read.sourceName, '&#x110000;&#99999999999999999999999;AB');
      expect(read.sourceSha1, _sample.sourceSha1);
      expect(StereoPhotoXmp.findIn(Uint8List.fromList(utf8.encode(damaged)))!.derivativeId, _sample.derivativeId);
    });

    test('a packet without our namespace, or without a Kind, is not ours', () {
      expect(
        StereoPhotoXmp.parse('<x:xmpmeta><rdf:Description GPano:ProjectionType="equirectangular"/></x:xmpmeta>'),
        isNull,
      );
      expect(
        StereoPhotoXmp.parse(
          '<rdf:Description xmlns:Immuch360="$immuch360XmpNamespace" Immuch360:SourceName="a.jpg"/>',
        ),
        isNull,
      );
      expect(StereoPhotoXmp.parse(''), isNull);
    });

    test('the settings key changes with each compared setting and nothing else', () {
      final key = _sample.settingsKey;

      expect(key, '$depthModelOnnxSha256|relief-v1|0.02|0.5|0');
      expect(_copy(sourceName: 'other.jpg').settingsKey, key);
      expect(_copy(derivativeId: 'urn:uuid:other').settingsKey, key);
      expect(_copy(parallax: 0.03).settingsKey, isNot(key));
      expect(_copy(convergence: 0.4).settingsKey, isNot(key));
      expect(_copy(quarterTurns: 1).settingsKey, isNot(key));
      expect(_copy(pipeline: 'relief-v2').settingsKey, isNot(key));
      expect(_copy(model: depthModelTfliteSha256).settingsKey, isNot(key));
    });

    test('found in the head of a JPEG, in its APP1 segment', () {
      final head = Uint8List.fromList([
        0xff, 0xd8, //
        ...xmpApp1Segment(fixture),
        0xff, 0xda, 0, 2, 1, 2, 3,
      ]);

      expect(StereoPhotoXmp.findIn(head), _sample);
      expect(StereoPhotoXmp.findIn(Uint8List.fromList(List.filled(4096, 0x41))), isNull);
    });

    test('the APP1 segment starts with the XMP signature and counts its own length', () {
      final segment = xmpApp1Segment('<x/>');

      expect(segment.sublist(0, 2), [0xff, 0xe1]);
      expect(segment[2] << 8 | segment[3], segment.length - 2);
      expect(ascii.decode(segment.sublist(4, 4 + xmpApp1Signature.length)), xmpApp1Signature);
      expect(() => xmpApp1Segment('x' * 70000), throwsArgumentError);
    });

    test('dates keep the offset of the computer', () {
      final local = DateTime(2026, 10, 27, 10, 12);
      final text = StereoPhotoXmp.xmpDateTime(local);

      expect(text, startsWith('2026-10-27T10:12:00'));
      expect(text, matches(RegExp(r'[+-]\d\d:\d\d$')));
    });
  });
}

StereoPhotoXmp _copy({
  String? sourceName,
  String? derivativeId,
  double? parallax,
  double? convergence,
  int? quarterTurns,
  String? pipeline,
  String? model,
}) => StereoPhotoXmp(
  eyes: _sample.eyes,
  eyeOrder: _sample.eyeOrder,
  depthModelSha256: model ?? _sample.depthModelSha256,
  pipeline: pipeline ?? _sample.pipeline,
  parallax: parallax ?? _sample.parallax,
  convergence: convergence ?? _sample.convergence,
  derivativeId: derivativeId ?? _sample.derivativeId,
  sourceName: sourceName ?? _sample.sourceName,
  sourceQuarterTurns: quarterTurns ?? _sample.sourceQuarterTurns,
);
