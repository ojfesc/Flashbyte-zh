import 'dart:io';
import 'dart:typed_data';

import 'package:flashbyte_core/protocol/frame_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('SocketReadBuffer', () {
    test('add and availableBytes', () {
      final buffer = SocketReadBuffer();
      expect(buffer.availableBytes, 0);
      buffer.add([1, 2, 3]);
      expect(buffer.availableBytes, 3);
    });

    test('tryReadBytes returns null when insufficient data', () {
      final buffer = SocketReadBuffer();
      buffer.add([1, 2]);
      expect(buffer.tryReadBytes(4), isNull);
    });

    test('tryReadBytes returns data when available', () {
      final buffer = SocketReadBuffer();
      buffer.add([1, 2, 3, 4]);
      final result = buffer.tryReadBytes(3);
      expect(result, [1, 2, 3]);
      expect(buffer.availableBytes, 1);
    });

    test('skipBytes consumes data', () {
      final buffer = SocketReadBuffer();
      buffer.add([1, 2, 3, 4, 5]);
      buffer.skipBytes(2);
      expect(buffer.availableBytes, 3);
      final result = buffer.tryReadBytes(3);
      expect(result, [3, 4, 5]);
    });

    test('tryPeekFrameHeader returns null on insufficient data', () {
      final buffer = SocketReadBuffer();
      buffer.add([0, 0, 0, 5]);
      expect(buffer.tryPeekFrameHeader(), isNull);
    });

    test('tryPeekFrameHeader parses 8-byte header', () {
      final buffer = SocketReadBuffer();
      final header = ByteData(8);
      header.setUint32(0, 100, Endian.big);
      header.setUint32(4, 200, Endian.big);
      buffer.add(header.buffer.asUint8List());
      final result = buffer.tryPeekFrameHeader();
      expect(result, isNotNull);
      expect(result!.headerLength, 100);
      expect(result.payloadLength, 200);
      // Peek should not consume
      expect(buffer.availableBytes, 8);
    });

    test('tryPeekBytes does not consume data', () {
      final buffer = SocketReadBuffer();
      buffer.add([10, 20, 30]);
      final result = buffer.tryPeekBytes(2);
      expect(result, [10, 20]);
      expect(buffer.availableBytes, 3);
    });

    test('skipBytes throws on insufficient data', () {
      final buffer = SocketReadBuffer();
      buffer.add([1]);
      expect(() => buffer.skipBytes(2), throwsRangeError);
    });
  });

  group('sendSocketFrame', () {
    test('sends metadata-only frame (no payload)', () async {
      final mockSocket = _MockSocket();
      await sendSocketFrame(mockSocket, {'type': 'test'});
      final data = mockSocket.written;
      expect(data.length, greaterThan(0));
      // Header: 8 bytes, then metadata JSON
      final header = ByteData.sublistView(Uint8List.fromList(data), 0, 8);
      final metadataLen = header.getUint32(0, Endian.big);
      final payloadLen = header.getUint32(4, Endian.big);
      expect(payloadLen, 0);
      expect(metadataLen, greaterThan(0));
    });

    test('sends frame with payload', () async {
      final mockSocket = _MockSocket();
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      await sendSocketFrame(mockSocket, {
        'type': 'data',
      }, payloadBytes: payload);
      final data = mockSocket.written;
      final header = ByteData.sublistView(Uint8List.fromList(data), 0, 8);
      final payloadLen = header.getUint32(4, Endian.big);
      expect(payloadLen, 5);
    });
  });

  group('configureSocketForTransfer', () {
    test('sets TCP no delay', () {
      final mockSocket = _MockSocket();
      configureSocketForTransfer(mockSocket);
      expect(mockSocket.tcpNoDelaySet, isTrue);
    });
  });

  group('FrameWriter', () {
    test('queues a control frame behind an in-flight data flush', () async {
      final socket = _GuardedMockSocket();
      final data = sendSocketFrame(
        socket,
        {'type': 'file_chunk'},
        payloadBytes: Uint8List.fromList(List.filled(32, 7)),
      );
      final ping = sendControlFrame(socket, {'type': 'ping'});

      await Future.wait([data, ping]);

      expect(socket.written.length, greaterThan(0));
      // The data frame is written first, then the ping frame.
      final firstHeader = ByteData.sublistView(
        Uint8List.fromList(socket.written),
        0,
        8,
      );
      final firstPayloadLength = firstHeader.getUint32(4, Endian.big);
      expect(firstPayloadLength, 32);
    });

    test('propagates a write failure and remembers the failure', () async {
      final socket = _GuardedMockSocket();
      socket.fail = true;

      await expectLater(
        sendSocketFrame(socket, {'type': 'file_chunk'}),
        throwsA(isA<FrameWriteException>()),
      );
      await expectLater(
        sendControlFrame(socket, {'type': 'ping'}),
        throwsA(isA<FrameWriteException>()),
      );
      expect(isFrameWriterFailed(socket), isTrue);
    });
  });

  group('FrameLimits', () {
    test('accepts headers inside the protocol limits', () {
      expect(
        isFrameHeaderValid(
          const FrameHeader(
            headerLength: 64,
            payloadLength: 1024 * 1024,
          ),
        ),
        isTrue,
      );
    });

    test('rejects oversized metadata', () {
      expect(
        isFrameHeaderValid(
          const FrameHeader(
            headerLength: FrameLimits.maxMetadataBytes + 1,
            payloadLength: 0,
          ),
        ),
        isFalse,
      );
    });

    test('rejects oversized payloads', () {
      expect(
        isFrameHeaderValid(
          const FrameHeader(
            headerLength: 8,
            payloadLength: FrameLimits.maxPayloadBytes + 1,
          ),
        ),
        isFalse,
      );
    });

    test('buffer reports overflow instead of growing without bound', () {
      final buffer = SocketReadBuffer();
      final chunk = Uint8List(FrameLimits.maxBufferedBytes);
      expect(buffer.add(chunk), isTrue);
      expect(buffer.add(const [0]), isFalse);
    });
  });
}

class _GuardedMockSocket {
  final List<int> written = [];
  bool fail = false;
  bool _flushing = false;

  void add(List<int> data) {
    if (_flushing) {
      throw StateError('StreamSink is bound to a stream');
    }
    if (fail) {
      throw StateError('write failed');
    }
    written.addAll(data);
  }

  Future<void> flush() async {
    if (fail) {
      throw StateError('write failed');
    }
    _flushing = true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    _flushing = false;
  }
}

class _MockSocket {
  final List<int> written = [];
  bool tcpNoDelaySet = false;

  void add(List<int> data) => written.addAll(data);
  Future<void> flush() async {}

  void setOption(Object option, Object value) {
    if (option == SocketOption.tcpNoDelay) {
      tcpNoDelaySet = value as bool;
    }
  }
}
