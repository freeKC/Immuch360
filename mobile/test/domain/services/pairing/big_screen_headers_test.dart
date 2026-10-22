import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/big_screen_headers.dart';

void main() {
  test('a big screen sends the name of its session and its OS', () {
    expect(bigScreenDeviceHeaders(label: 'Living room TV', os: 'Android'), {
      'deviceModel': 'Immuch360 on Living room TV',
      'deviceType': 'Android',
    });
  });

  test('a phone, without a name, sends nothing', () {
    expect(bigScreenDeviceHeaders(label: null, os: 'Android'), isEmpty);
    expect(bigScreenDeviceHeaders(label: '  ', os: 'Android'), isEmpty);
  });

  test('a header value is printable ASCII, accents dropped', () {
    expect(asciiHeaderValue('Télé du salon'), 'Tele du salon');
    expect(asciiHeaderValue('Fred’s Œuvre ß'), "Fred's OEuvre ss");
    expect(asciiHeaderValue('客厅\n电视'), '?????');
    expect(bigScreenDeviceHeaders(label: 'Télé', os: 'Windows')['deviceModel'], 'Immuch360 on Tele');
  });
}
