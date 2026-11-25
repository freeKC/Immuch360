// The release of the catalogue of the AI components (aiComponentsCatalogueRelease) follows the version of the app:
// another version sharing the folder of the components tells by it whether a file was installed by a newer one
// (review of issue 21, release 52). A version change without it fails here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';

void main() {
  test('the release of the catalogue is the versionCode of pubspec.yaml less 3029998', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*\S+\+(\d+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(int.parse(match!.group(1)!) - 3029998, aiComponentsCatalogueRelease);
  });
}
