// The framing of the Cast v2 channel: a message cut across reads, several in one read, a frame too large

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_channel.dart';

void main() {
  List<int> frame(String payload) => encodeCastFrame(
    source: 'sender-immuch360',
    destination: castReceiverId,
    namespace: castNamespaceReceiver,
    payload: payload,
  );

  test('a message cut in three reads comes once whole', () {
    final bytes = frame(jsonEncode({'type': 'LAUNCH', 'appId': castDefaultReceiverAppId, 'requestId': 1}));
    final reader = CastFrameReader();
    expect(reader.add(bytes.sublist(0, 3)), isEmpty);
    expect(reader.add(bytes.sublist(3, 20)), isEmpty);
    final messages = reader.add(bytes.sublist(20));
    expect(messages, hasLength(1));
    expect(messages.single.namespace, castNamespaceReceiver);
    expect(messages.single.destinationId, castReceiverId);
    expect(jsonDecode(messages.single.payloadUtf8), {'type': 'LAUNCH', 'appId': 'CC1AD845', 'requestId': 1});
  });

  test('two messages and the start of a third in one read', () {
    final first = frame('{"type":"PING"}');
    final second = frame('{"type":"PONG"}');
    final third = frame('{"type":"GET_STATUS"}');
    final reader = CastFrameReader();
    final messages = reader.add([...first, ...second, ...third.sublist(0, 5)]);
    expect(messages.map((message) => message.payloadUtf8), ['{"type":"PING"}', '{"type":"PONG"}']);
    expect(reader.add(third.sublist(5)).single.payloadUtf8, '{"type":"GET_STATUS"}');
  });

  test('a frame announced larger than the limit is refused', () {
    final reader = CastFrameReader();
    expect(() => reader.add([0x00, 0x10, 0x00, 0x01, 0x00]), throwsFormatException);
  });
}
