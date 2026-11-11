// The licences of the AV2 decoder (av2_decoder_licences.dart, av2_licenses.dart; store/m2/av2-2026-11-02/
// plan-2026-11-02.md, section 3): the texts the app keeps are the files of dav2d at the pinned commit (the SHA-256 the
// catalogue gives for the licenses/ of each archive of github.com/immuch360/av2-companion v1.0.1), nothing under the
// GPL; the licence dialog of the decoder gives them; the licence page lists dav2d, the patent licence, immuch360-av2
// and on Linux immuch360-run, from the licenses/ folder of the decoder once installed.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/desktop/video/av2_licenses.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_licences.dart';
import 'package:immich_mobile/domain/services/ai_immersive/av2_decoder_licences.dart';
import 'package:path/path.dart' as p;

import 'av2_test_components.dart';

String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();

List<String> _paragraphs(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).toList();

void main() {
  group('the texts the app keeps', () {
    test('are the files of dav2d at the commit of the lock, and the licence of immuch360-run', () {
      // COPYING and doc/PATENTS: the sums of the lock of av2-companion; x86inc-ISC.txt: lines 1 to 21 of
      // src/ext/x86/x86inc.asm; immuch360-run-MIT.txt: the text of the Linux archive
      expect(_sha256(dav2dCopying), 'c8380b7afd97b17c2d645122001f534d877d6b2612c1138acb9c41f7750c9c7b');
      expect(_sha256(aomPatentLicence), '335eca574598bf4ca181b12f708d6669e5a5e78c8e1513e5b35fa1f03901484b');
      expect(_sha256(x86incIsc), '1c20545ce9b2407beccfcf88f33fd0588e8988afaeef31bed7acc30803d2204c');
      expect(_sha256(immuch360RunMit), 'e1ca99633c8cb8df3e8189b0c4b804e91b6dca413ae4022ea3d905e0f94ef191');
      expect(av2Dav2dCommit, '30140b563596a1b14aef808ff021c90288948315');
      expect(dav2dCopying, startsWith('Copyright © 2018-2026, VideoLAN and dav2d authors'));
      expect(aomPatentLicence, startsWith('Alliance for Open Media Patent License 1.0'));
    });

    test('are the licence files the archives of the decoder carry (av2-companion v1.0.1)', () {
      final kept = {
        'licenses/dav2d-COPYING.txt': dav2dCopying,
        'licenses/AOM-PATENTS.txt': aomPatentLicence,
        'licenses/x86inc-ISC.txt': x86incIsc,
        'licenses/immuch360-run-MIT.txt': immuch360RunMit,
      };
      for (final component in [av2DecoderWindowsComponent, av2DecoderLinuxComponent, av2DecoderMacComponent]) {
        final files = {for (final file in component.archiveFiles) file.path: file};
        for (final MapEntry(key: path, value: text) in kept.entries) {
          if (path.contains('immuch360-run') && !component.platforms.contains(AiPlatform.linuxX64)) {
            expect(files, isNot(contains(path)), reason: component.id);
            continue;
          }
          expect(files[path]?.sha256, _sha256(text), reason: '${component.id} $path');
          expect(files[path]?.size, utf8.encode(text).length, reason: '${component.id} $path');
        }
        // Ours: the MIT licence and where its source is, read from the archive once installed
        expect(files, contains('licenses/immuch360-av2-MIT.txt'), reason: component.id);
        expect(files, contains('licenses/immuch360-av2-SOURCE.txt'), reason: component.id);
        expect(files.keys.where((path) => path.contains('AGPL')), isEmpty, reason: component.id);
        // Its version is the id of the lock, its licence the COPYING of the commit of the lock
        expect(component.version, '30140b5-1');
        expect(component.assetName, contains('-30140b5-1-'));
        expect(component.licenceUrl, 'https://code.videolan.org/videolan/dav2d/-/blob/$av2Dav2dCommit/COPYING');
      }
    });

    test('hold nothing under the GPL', () {
      for (final text in [dav2dCopying, x86incIsc, aomPatentLicence, immuch360RunMit]) {
        expect(text, isNot(contains('General Public License')));
        expect(text, isNot(contains('GPL')));
      }
      // Ours is under the MIT licence, in its own repository
      expect(av2CompanionNotice, contains('under the MIT licence'));
      expect(av2CompanionNotice, contains('https://github.com/immuch360/av2-companion'));
      expect(av2CompanionNotice, isNot(contains('Affero')));
    });

    test('are what the licence dialog of the decoder shows, immuch360-run on Linux only', () {
      final windows = aiLicenceText(av2DecoderWindowsComponent);
      for (final part in [av2CompanionNotice, dav2dCopying, x86incIsc, aomPatentLicence]) {
        expect(windows, contains(part));
      }
      expect(windows, isNot(contains(immuch360RunMit)));
      expect(aiLicenceText(av2DecoderMacComponent), isNot(contains(immuch360RunMit)));
      expect(aiLicenceText(av2DecoderLinuxComponent), contains(immuch360RunMit));
      // Another component under a BSD licence keeps its own text
      expect(aiLicenceText(upscalerComponent), isNot(contains('dav2d')));
    });
  });

  group('the licence page', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('av2_licenses_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    /// The entries of a version that offers the decoder (the sums of the test build), unless [catalogue] says else
    Future<List<LicenseEntry>> entries(
      AiPlatform? platform, {
      Future<Directory> Function()? folder,
      List<AiComponent>? catalogue,
    }) => av2LicenseEntries(
      folder ?? () async => dir,
      platform: platform,
      catalogue: catalogue ?? av2CompleteCatalogue,
    ).toList();

    test(
      'before the decoder is downloaded: dav2d, the patent licence and immuch360-av2, from the kept texts',
      () async {
        final listed = await entries(AiPlatform.windowsX64);
        expect(listed.map((entry) => entry.packages.single), [
          'dav2d (AV2 decoder)',
          'Alliance for Open Media Patent License 1.0',
          'immuch360-av2',
        ]);
        final dav2d = _paragraphs(listed[0]).join('\n');
        expect(dav2d, contains('until the decoder is downloaded'));
        expect(dav2d, contains('Copyright © 2018-2026, VideoLAN and dav2d authors'));
        expect(dav2d, contains('Copyright (C) 2005-2024 x264 project'));
        expect(_paragraphs(listed[1]).join('\n'), contains('1.1. Patent License.'));
        expect(_paragraphs(listed[2]).join('\n'), contains('under the MIT licence'));
      },
    );

    test('the header of x86inc.asm reads as text: no comment marks, a paragraph for each of its parts', () async {
      final dav2d = _paragraphs((await entries(AiPlatform.windowsX64))[0]);
      expect(dav2d.where((paragraph) => paragraph.contains(';*') || paragraph.contains('*****')), isEmpty);
      expect(dav2d, contains('x86inc.asm: x86 abstraction layer'));
      expect(dav2d, contains('Copyright (C) 2005-2024 x264 project'));
      expect(
        dav2d,
        contains(
          'Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is '
          'hereby granted, provided that the above copyright notice and this permission notice appear in all copies.',
        ),
      );
      expect(dav2d.where((paragraph) => paragraph.startsWith('THE SOFTWARE IS PROVIDED "AS IS"')), hasLength(1));
      // The kept text itself stays the header of the file, byte for byte
      expect(x86incIsc, startsWith(';****'));
    });

    test('a text that is no assembly comment stays as it is, a comment loses its marks and its rules', () {
      expect(
        av2LicencePageText('ISC of the archive\n\nsecond paragraph\n'),
        'ISC of the archive\n\nsecond paragraph\n',
      );
      expect(av2LicencePageText(dav2dCopying), dav2dCopying);
      expect(av2LicencePageText(';* a\n;*\n;* b\nnot a comment\n'), ';* a\n;*\n;* b\nnot a comment\n');
      expect(av2LicencePageText(';****\n;* a\n;****\n;* b\n;*   c\n;*\n;* d\n'), 'a\n\nb\n  c\n\nd');
    });

    test('a version that does not offer the decoder never says it downloads, and lists the same texts', () async {
      // A catalogue whose entries of the decoder have no sums, as before the first release of the decoder
      expect(av2DecoderComponentFor(AiPlatform.windowsX64, catalogue: av2IncompleteCatalogue)?.isComplete, isFalse);
      final listed = await entries(AiPlatform.windowsX64, catalogue: av2IncompleteCatalogue);
      expect(listed, hasLength(3));
      final dav2d = _paragraphs(listed[0]).join('\n');
      expect(dav2d, isNot(contains('downloaded')));
      expect(dav2d, contains('The texts below are those of the AV2 decoder, kept in Immuch360.'));
      expect(dav2d, contains('Copyright © 2018-2026, VideoLAN and dav2d authors'));
    });

    test('on Linux, immuch360-run too; nothing where there is no decoder', () async {
      final linux = await entries(AiPlatform.linuxX64);
      expect(linux.last.packages, ['immuch360-run']);
      expect(_paragraphs(linux.last).join('\n'), contains('Permission is hereby granted'));
      expect(await entries(AiPlatform.macosArm64), hasLength(3));
      expect(await entries(null), isEmpty);
      expect(await entries(AiPlatform.questArm64), isEmpty);
    });

    test(
      'once installed, the texts of its licenses folder, with its MIT licence and the commit it was built from',
      () async {
        final licenses = Directory(p.join(dir.path, 'engines', 'av2-decoder-windows-x64', 'licenses'))
          ..createSync(recursive: true);
        // CRLF, as a copy on Windows may give
        File(p.join(licenses.path, 'dav2d-COPYING.txt')).writeAsStringSync('COPYING of the archive\r\nline 2\r\n');
        File(p.join(licenses.path, 'x86inc-ISC.txt')).writeAsStringSync('ISC of the archive\n');
        File(p.join(licenses.path, 'AOM-PATENTS.txt')).writeAsStringSync('PATENTS of the archive\n');
        File(p.join(licenses.path, 'immuch360-av2-MIT.txt')).writeAsStringSync('MIT License of the archive\n');
        File(
          p.join(licenses.path, 'immuch360-av2-SOURCE.txt'),
        ).writeAsStringSync('https://github.com/immuch360/av2-companion/tree/abc1234\n');

        final listed = await entries(AiPlatform.windowsX64);
        final dav2d = _paragraphs(listed[0]).join('\n');
        expect(dav2d, contains('of the decoder installed on this computer'));
        expect(dav2d, contains('COPYING of the archive'));
        expect(dav2d, contains('line 2'));
        expect(dav2d, isNot(contains('\r')));
        expect(dav2d, contains('ISC of the archive'));
        expect(_paragraphs(listed[1]).join('\n'), contains('PATENTS of the archive'));
        final companion = _paragraphs(listed[2]).join('\n');
        expect(companion, contains('MIT License of the archive'));
        expect(companion, contains('av2-companion/tree/abc1234'));
      },
    );

    test('a file missing from the folder, or a folder that cannot be read, gives the kept texts', () async {
      Directory(p.join(dir.path, 'engines', 'av2-decoder-windows-x64', 'licenses')).createSync(recursive: true);
      final listed = await entries(AiPlatform.windowsX64);
      expect(_paragraphs(listed[0]).join('\n'), contains('Copyright © 2018-2026, VideoLAN and dav2d authors'));

      final failing = await entries(AiPlatform.windowsX64, folder: () async => throw const FileSystemException('no'));
      expect(failing, hasLength(3));
      expect(_paragraphs(failing[0]).join('\n'), contains('until the decoder is downloaded'));
    });
  });
}
