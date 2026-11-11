import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/device_decoder_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('read once, then kept', () async {
    var reads = 0;
    final types = DeviceDecoderTypes(
      read: () async {
        reads++;
        return {'video/avc', 'audio/eac3'};
      },
    );
    expect(await types.types(), {'video/avc', 'audio/eac3'});
    expect(await types.types(), {'video/avc', 'audio/eac3'});
    expect(reads, 1);
  });

  test('a read that told nothing is tried again at the next call', () async {
    var reads = 0;
    final types = DeviceDecoderTypes(
      read: () async {
        reads++;
        return reads == 1 ? null : {'video/hevc'};
      },
    );
    expect(await types.types(), isNull);
    expect(await types.types(), {'video/hevc'});
    expect(await types.types(), {'video/hevc'});
    expect(reads, 2);
  });

  group('the Android channel', () {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(DeviceDecoderTypes.channel, null));

    test('the MIME types in lower case', () async {
      messenger.setMockMethodCallHandler(DeviceDecoderTypes.channel, (call) async {
        expect(call.method, 'mimeTypes');
        return ['video/AVC', 'audio/eac3'];
      });
      expect(await DeviceDecoderTypes().types(), {'video/avc', 'audio/eac3'});
    });

    test('nothing where the platform does not answer, or fails', () async {
      expect(await DeviceDecoderTypes().types(), isNull);
      messenger.setMockMethodCallHandler(
        DeviceDecoderTypes.channel,
        (call) async => throw PlatformException(code: 'DECODERS_FAILED'),
      );
      expect(await DeviceDecoderTypes().types(), isNull);
    });
  });
}
