import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/local_only_message.dart';
import 'package:immich_mobile/desktop/network/computer_share.dart';
import 'package:immich_mobile/generated/translations.g.dart';

import 'english_texts.dart';

void main() {
  setUp(loadEnglishTexts);

  test('a network folder: no message, the Quest finds the photo there', () {
    expect(localOnlyMessage(StaticTranslations.instance, isNetwork: true, computerShare: true), isNull);
    expect(localOnlyMessage(StaticTranslations.instance, isNetwork: true, computerShare: false), isNull);
  });

  test('a folder of this computer on Windows: the network folder or Share this computer', () {
    expect(
      localOnlyMessage(StaticTranslations.instance, isNetwork: false, computerShare: true),
      'Saved on this computer only. To see it in the Quest, save it to a network folder (NAS) or turn on Share this '
      'computer.',
    );
  });

  test('a folder of this computer on Linux and macOS: the network folder only, they have no share of the computer', () {
    expect(
      localOnlyMessage(StaticTranslations.instance, isNetwork: false, computerShare: false),
      'Saved on this computer only. To see it in the Quest, save it to a network folder (NAS).',
    );
  });

  test('this computer decides by default', () {
    expect(
      localOnlyMessage(StaticTranslations.instance, isNetwork: false),
      localOnlyMessage(StaticTranslations.instance, isNetwork: false, computerShare: computerShareAvailable),
    );
  });
}
