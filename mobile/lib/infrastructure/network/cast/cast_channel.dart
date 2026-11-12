// The Cast v2 channel to a Cast device: TLS to its port (8009), messages framed by a four byte big-endian length then
// the CastMessage protobuf of the `cast` package (MIT), whose payload is JSON. The package's own socket takes each TCP
// read as one whole message, which a long RECEIVER_STATUS split in two reads breaks: this reader frames the bytes
// itself and keeps the protobuf class only.
//
// The device's certificate is its own, signed by Google's device CA; like every sender without the device
// authentication challenge, the channel accepts it as it is. Nothing secret goes through it: the relay's one time
// address, the film's texts and the transport commands.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cast/cast_channel/cast_channel.pb.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';

/// One message of a channel
class CastChannelMessage {
  const CastChannelMessage({required this.namespace, required this.source, required this.payload});

  final String namespace;

  /// Who sent it: "receiver-0" for the platform, the transport id of the receiver application
  final String source;
  final Map<String, Object?> payload;
}

/// A connection to a Cast device, replaced in the tests
abstract class CastChannel {
  /// The JSON messages of the device, in order; done when the connection ends
  Stream<CastChannelMessage> get messages;

  /// Sends [payload] to [destination] on [namespace], with a request id when it has none
  void send(String namespace, Map<String, Object?> payload, {String destination = castReceiverId});

  Future<void> close();
}

/// The largest message taken: a receiver status is a few KiB
const castMaxFrameBytes = 64 * 1024;

/// The bytes of one framed message
Uint8List encodeCastFrame({
  required String source,
  required String destination,
  required String namespace,
  required String payload,
}) {
  final message = CastMessage()
    ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
    ..sourceId = source
    ..destinationId = destination
    ..namespace = namespace
    ..payloadType = CastMessage_PayloadType.STRING
    ..payloadUtf8 = payload;
  final body = message.writeToBuffer();
  final frame = Uint8List(4 + body.length);
  ByteData.sublistView(frame).setUint32(0, body.length);
  frame.setRange(4, frame.length, body);
  return frame;
}

/// Gathers the bytes of a connection into whole messages, whatever the reads cut
class CastFrameReader {
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  /// The messages [chunk] completes; throws [FormatException] for a frame larger than [castMaxFrameBytes]
  List<CastMessage> add(List<int> chunk) {
    _buffer
      ..add(_pending)
      ..add(chunk);
    var bytes = _buffer.takeBytes();
    final messages = <CastMessage>[];
    while (bytes.length >= 4) {
      final length = ByteData.sublistView(bytes).getUint32(0);
      if (length > castMaxFrameBytes) {
        throw FormatException('Cast frame of $length bytes');
      }
      if (bytes.length < 4 + length) {
        break;
      }
      messages.add(CastMessage.fromBuffer(Uint8List.sublistView(bytes, 4, 4 + length)));
      bytes = Uint8List.sublistView(bytes, 4 + length);
    }
    _pending = Uint8List.fromList(bytes);
    return messages;
  }
}

/// The channel over TLS
class CastSocketChannel implements CastChannel {
  CastSocketChannel._(this._socket, this._sender) {
    final reader = CastFrameReader();
    _subscription = _socket.listen(
      (chunk) {
        final List<CastMessage> received;
        try {
          received = reader.add(chunk);
        } on FormatException catch (error) {
          _controller.addError(error);
          unawaited(close());
          return;
        }
        for (final message in received) {
          if (message.payloadType != CastMessage_PayloadType.STRING) {
            continue;
          }
          final Object? payload;
          try {
            payload = jsonDecode(message.payloadUtf8);
          } on FormatException {
            continue;
          }
          if (payload is! Map<String, Object?>) {
            continue;
          }
          _controller.add(CastChannelMessage(namespace: message.namespace, source: message.sourceId, payload: payload));
        }
      },
      onError: (Object error) => _controller.addError(error),
      onDone: () => unawaited(close()),
      cancelOnError: false,
    );
  }

  /// Connects to [host]:[port] as [sender] (a "sender-..." id of this phone)
  static Future<CastSocketChannel> connect(
    String host,
    int port, {
    String sender = 'sender-immuch360',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // ignore: close_sinks, the channel destroys it in close
    final socket = await SecureSocket.connect(host, port, onBadCertificate: (_) => true, timeout: timeout);
    return CastSocketChannel._(socket, sender);
  }

  final SecureSocket _socket;
  final String _sender;
  late final StreamSubscription<Uint8List> _subscription;
  final _controller = StreamController<CastChannelMessage>.broadcast();
  int _requestId = 1;
  bool _closed = false;

  @override
  Stream<CastChannelMessage> get messages => _controller.stream;

  @override
  void send(String namespace, Map<String, Object?> payload, {String destination = castReceiverId}) {
    if (_closed) {
      return;
    }
    final body = {...payload};
    // The connection and heartbeat messages have no request id
    if (namespace != castNamespaceConnection && namespace != castNamespaceHeartbeat) {
      body['requestId'] ??= _requestId++;
    }
    _socket.add(
      encodeCastFrame(source: _sender, destination: destination, namespace: namespace, payload: jsonEncode(body)),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _socket.flush().timeout(const Duration(seconds: 1));
    } catch (_) {
      // Gone already
    }
    await _subscription.cancel();
    _socket.destroy();
    await _controller.close();
  }
}
