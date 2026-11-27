import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class FrameHeader {
  const FrameHeader({required this.headerLength, required this.payloadLength});

  final int headerLength;
  final int payloadLength;
}

/// Upper bounds for a single frame.
///
/// Metadata is a small JSON header while payloads carry file chunks of about
/// one megabyte. A peer that announces more than this is treated as broken or
/// hostile, so the receiver never buffers an unbounded amount of memory.
class FrameLimits {
  const FrameLimits._();

  /// Largest JSON metadata block accepted for one frame.
  ///
  /// Batch requests carry one entry per file, so a folder with thousands of
  /// files produces a large header; 4 MB covers tens of thousands of files while
  /// still bounding what a hostile peer can make the receiver allocate.
  static const int maxMetadataBytes = 4 * 1024 * 1024;

  /// Largest binary payload accepted for one frame.
  static const int maxPayloadBytes = 32 * 1024 * 1024;

  /// Largest amount of unread data kept in [SocketReadBuffer].
  static const int maxBufferedBytes = maxMetadataBytes + maxPayloadBytes + 8;
}

/// Raised when a frame header exceeds [FrameLimits].
class InvalidFrameHeaderException implements Exception {
  const InvalidFrameHeaderException(this.message);

  final String message;

  @override
  String toString() => 'InvalidFrameHeaderException: $message';
}

/// Whether [header] stays inside the protocol limits.
bool isFrameHeaderValid(FrameHeader header) {
  return header.headerLength <= FrameLimits.maxMetadataBytes &&
      header.payloadLength <= FrameLimits.maxPayloadBytes;
}

/// Queue-based byte buffer for reading length-prefixed frames from a socket.
class SocketReadBuffer {
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _headOffset = 0;
  int _availableBytes = 0;

  int get availableBytes => _availableBytes;

  /// Adds raw bytes received from the socket.
  ///
  /// Returns false when the buffer grows past [FrameLimits.maxBufferedBytes],
  /// which means the peer announced a frame larger than the protocol allows or
  /// the consumer stopped draining. The caller must close the connection.
  bool add(List<int> bytes) {
    if (bytes.isEmpty) {
      return true;
    }

    _chunks.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _availableBytes += bytes.length;
    return _availableBytes <= FrameLimits.maxBufferedBytes;
  }

  FrameHeader? tryPeekFrameHeader() {
    final bytes = tryPeekBytes(8);
    if (bytes == null) {
      return null;
    }

    final header = ByteData.sublistView(bytes);
    return FrameHeader(
      headerLength: header.getUint32(0, Endian.big),
      payloadLength: header.getUint32(4, Endian.big),
    );
  }

  Uint8List? tryPeekBytes(int byteCount) {
    if (_availableBytes < byteCount) {
      return null;
    }

    final out = Uint8List(byteCount);
    var outOffset = 0;
    var remaining = byteCount;
    var chunkOffset = _headOffset;

    for (final chunk in _chunks) {
      final readable = chunk.length - chunkOffset;
      final take = (readable < remaining ? readable : remaining).toInt();
      out.setRange(outOffset, outOffset + take, chunk, chunkOffset);
      outOffset += take;
      remaining -= take;
      if (remaining == 0) {
        break;
      }
      chunkOffset = 0;
    }

    return out;
  }

  void skipBytes(int byteCount) {
    if (_availableBytes < byteCount) {
      throw RangeError.range(byteCount, 0, _availableBytes, 'byteCount');
    }
    _consume(byteCount);
  }

  Uint8List? tryReadBytes(int byteCount) {
    if (_availableBytes < byteCount) {
      return null;
    }

    final out = Uint8List(byteCount);
    var outOffset = 0;
    var remaining = byteCount;

    while (remaining > 0) {
      final head = _chunks.first;
      final readable = head.length - _headOffset;
      final take = (readable < remaining ? readable : remaining).toInt();
      out.setRange(outOffset, outOffset + take, head, _headOffset);
      _consume(take);
      outOffset += take;
      remaining -= take;
    }

    return out;
  }

  void _consume(int byteCount) {
    _availableBytes -= byteCount;
    _headOffset += byteCount;

    while (_chunks.isNotEmpty && _headOffset >= _chunks.first.length) {
      _headOffset -= _chunks.removeFirst().length.toInt();
    }

    if (_chunks.isEmpty) {
      _headOffset = 0;
    }
  }
}

/// Raised when a frame cannot be written to its socket.
///
/// The original error is kept in [cause] so callers can distinguish a dead
/// socket from a transient write failure.
class FrameWriteException implements Exception {
  const FrameWriteException(this.cause, [this.stackTrace]);

  final Object cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'FrameWriteException: $cause';
}

/// Serializes every frame written to one socket.
///
/// Dart's socket sink rejects `add` while another `flush` is pending, which is
/// exactly the window a heartbeat timer used to hit. Frames are therefore
/// chained on one future: data and control frames keep their order, and a
/// control frame waits for the in-flight chunk instead of being dropped.
class _FrameWriter {
  _FrameWriter(this.socket);

  final dynamic socket;
  Future<void> _tail = Future<void>.value();
  Object? _failure;

  Future<void> send(Map<String, dynamic> payload, Uint8List? body) {
    final failure = _failure;
    if (failure != null) {
      return Future<void>.error(FrameWriteException(failure));
    }

    final header = ByteData(8);
    final metadata = utf8.encode(jsonEncode(payload));
    header.setUint32(0, metadata.length, Endian.big);
    header.setUint32(4, body?.length ?? 0, Endian.big);
    final headerBytes = header.buffer.asUint8List();

    final next = _tail.then((_) async {
      final currentFailure = _failure;
      if (currentFailure != null) {
        throw FrameWriteException(currentFailure);
      }
      try {
        socket.add(headerBytes);
        socket.add(metadata);
        if (body != null && body.isNotEmpty) {
          socket.add(body);
        }
        await socket.flush();
      } catch (e, st) {
        _failure = e;
        throw FrameWriteException(e, st);
      }
    });

    // Keep the chain alive after a failure; the next caller still receives the
    // original error through [send].
    _tail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }
}

final Expando<_FrameWriter> _frameWriters = Expando<_FrameWriter>(
  'flashbyte-frame-writers',
);

_FrameWriter _writerFor(dynamic socket) {
  if (socket == null) {
    throw const FrameWriteException('Socket is null');
  }
  return _frameWriters[socket] ??= _FrameWriter(socket);
}

/// Whether the socket's frame writer has already failed.
///
/// Used by the heartbeat to avoid waiting for a write that can never succeed.
bool isFrameWriterFailed(dynamic socket) {
  if (socket == null) {
    return true;
  }
  return _frameWriters[socket]?._failure != null;
}

/// Encodes and sends a length-prefixed frame over a socket.
///
/// Frame format: [4 bytes metadata length][4 bytes payload length][metadata][payload]
Future<void> sendSocketFrame(
  dynamic socket,
  Map<String, dynamic> payload, {
  Uint8List? payloadBytes,
}) {
  return _writerFor(socket).send(payload, payloadBytes);
}

/// Sends a control frame (zero-payload frame carrying only metadata).
Future<void> sendControlFrame(dynamic socket, Map<String, dynamic> payload) {
  return _writerFor(socket).send(payload, null);
}

/// Configures a socket for low-latency file transfer.
void configureSocketForTransfer(dynamic socket) {
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {}
}
