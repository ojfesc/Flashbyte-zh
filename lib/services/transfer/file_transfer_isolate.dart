import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flashbyte/services/platform/android_saf_service.dart';
import 'package:flashbyte/services/security/tls_identity_service.dart';
import 'package:flashbyte_core/flashbyte_core.dart' as core;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';
import 'package:uuid/uuid.dart';

// Top-level maps live in the isolate's own global scope. They are shared by
// the receive handler and the send command without threading another couple of
// callbacks through every socket connection.
final _sendingFileSizes = <String, int>{};
final _resumeOffsets = <String, int>{};

/// Serializes partial-file cleanup with a reconnect that may reopen the same
/// partial file. Without this, a new connection could append while the old
/// receiver handler is still closing its sink.
Future<void> _pendingReceiveCleanup = Future<void>.value();

void fileReceiverIsolate(List<Object> args) {
  final toUiSendPort = args[0] as SendPort;
  final RootIsolateToken rootIsolateToken = args[1] as RootIsolateToken;

  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  final fromUiReceivePort = ReceivePort();
  toUiSendPort.send(fromUiReceivePort.sendPort);

  dynamic clientSocket;
  dynamic serverSocket;
  String? currentDownloadDirectory;

  final Queue<Map<String, dynamic>> commandQueue =
      Queue<Map<String, dynamic>>();
  bool isProcessing = false;
  bool isSendingFile = false;
  bool localDisconnectRequested = false;
  String? sendingFileId;
  final locallyPausedTransfers = <String, String>{};
  final remotelyPausedTransfers = <String, String>{};
  final locallyCancelledTransfers = <String>{};
  final remotelyCancelledTransfers = <String>{};
  final acceptedTransfers = <String>{};
  final declinedTransfers = <String>{};
  // Offset reported by the peer for a resumed file, keyed by the current file
  // id. Cleared once the file has been started.
  final remoteResumeOffsets = <String, int>{};

  bool isTransferPaused(String fileId) {
    return locallyPausedTransfers.containsKey(fileId) ||
        remotelyPausedTransfers.containsKey(fileId);
  }

  void sendTransferPausedState(String fileId, {String? pausedBy}) {
    final owner =
        pausedBy ??
        locallyPausedTransfers[fileId] ??
        remotelyPausedTransfers[fileId];
    toUiSendPort.send({
      'status': 'transfer_paused',
      'fileId': fileId,
      'pausedBy': owner,
      'canResume': locallyPausedTransfers.containsKey(fileId),
    });
  }

  void sendTransferResumeState(String fileId) {
    if (isTransferPaused(fileId)) {
      sendTransferPausedState(fileId);
      return;
    }

    toUiSendPort.send({'status': 'transfer_resumed', 'fileId': fileId});
  }

  void handleRemoteTransferPaused(String fileId, {String? pausedBy}) {
    remotelyPausedTransfers[fileId] = pausedBy ?? 'remote';
    sendTransferPausedState(fileId, pausedBy: pausedBy);
  }

  void handleRemoteTransferResumed(String fileId, {String? pausedBy}) {
    remotelyPausedTransfers.remove(fileId);
    sendTransferResumeState(fileId);
  }

  void handleRemoteTransferCancelled(String fileId) {
    remotelyCancelledTransfers.add(fileId);
    locallyPausedTransfers.remove(fileId);
    remotelyPausedTransfers.remove(fileId);
    toUiSendPort.send({'status': 'transfer_cancelled', 'fileId': fileId});
  }

  void handleRemoteTransferAccepted(String fileId) {
    acceptedTransfers.add(fileId);
    declinedTransfers.remove(fileId);
    toUiSendPort.send({'status': 'transfer_accepted', 'fileId': fileId});
  }

  void handleRemoteTransferDeclined(String fileId) {
    declinedTransfers.add(fileId);
    acceptedTransfers.remove(fileId);
    remotelyCancelledTransfers.add(fileId);
    toUiSendPort.send({'status': 'transfer_declined', 'fileId': fileId});
    toUiSendPort.send({'status': 'transfer_cancel_ready', 'fileId': fileId});
  }

  String transferControlType(String role, String action) {
    final normalizedRole = role == 'sender' ? 'sender' : 'receiver';
    return '${normalizedRole}_$action';
  }

  Future<void> processCommandQueue() async {
    if (isProcessing || commandQueue.isEmpty) return;
    isProcessing = true;

    while (commandQueue.isNotEmpty) {
      final command = commandQueue.removeFirst();

      try {
        if (command['command'] == 'connect') {
          final useTLS = command['useTLS'] ?? false;
          currentDownloadDirectory = command['downloadDirectory'] as String?;
          final localPeerInfo = <String, dynamic>{
            'type': 'peer_info',
            'name': command['deviceName'],
            'deviceType': command['deviceType'],
            'port': command['listeningPort'],
            'tls': useTLS,
            'certFingerprint': command['certificateFingerprint'],
          };

          if (command['mode'] == 'host') {
            SecurityContext? securityContext;
            if (useTLS) {
              try {
                final certPath = command['certPath'] as String?;
                final keyPath = command['keyPath'] as String?;

                if (certPath != null && keyPath != null) {
                  securityContext = SecurityContext(withTrustedRoots: false);
                  securityContext.useCertificateChain(certPath);
                  securityContext.usePrivateKey(keyPath);
                } else {
                  throw Exception('Generated certificate files not found.');
                }
              } catch (e) {
                toUiSendPort.send({
                  'status': 'error',
                  'fatal': 'true',
                  'message': 'Failed to load certificate: ${e.toString()}',
                });
                return;
              }
            }

            if (useTLS) {
              serverSocket = await SecureServerSocket.bind(
                "0.0.0.0",
                command['port'],
                securityContext!,
                shared: true,
              );
            } else {
              serverSocket = await ServerSocket.bind(
                "0.0.0.0",
                command['port'],
                shared: true,
              );
            }

            toUiSendPort.send({
              'status': 'hosting',
              'address': serverSocket!.address.address,
            });

            dynamic savedClientSocket;

            serverSocket!.listen(
              (socket) {
                // Only one transfer socket is meaningful at a time. Close a
                // half-open previous client so its cleanup can run before the
                // resumed file reopens the partial output.
                try {
                  clientSocket?.destroy();
                } catch (_) {}
                savedClientSocket = socket;
                core.configureSocketForTransfer(savedClientSocket);
                clientSocket = socket;
                if (useTLS) {
                  // TLS handshake already verified the client — notify UI immediately
                  toUiSendPort.send({'status': 'client_connected'});
                } else {
                  // Non-TLS: notify UI that a client is connecting (probe in progress)
                  toUiSendPort.send({'status': 'client_connecting'});
                }
                // Non-TLS servers wait for probe before sending client_connected
                _handleSocketConnection(
                  savedClientSocket,
                  toUiSendPort,
                  waitForProbe: !useTLS,
                  getDownloadDirectory: () => currentDownloadDirectory,
                  shouldSuppressConnectionErrors: () =>
                      localDisconnectRequested,
                  shouldCancelReceivingFile: (fileId) =>
                      locallyCancelledTransfers.contains(fileId),
                  localPeerInfo: localPeerInfo,
                  onRemoteTransferPaused: handleRemoteTransferPaused,
                  onRemoteTransferResumed: handleRemoteTransferResumed,
                  onRemoteTransferCancelled: handleRemoteTransferCancelled,
                  onRemoteTransferAccepted: handleRemoteTransferAccepted,
                  onRemoteTransferOffset: (fileId, offset) {
                    remoteResumeOffsets[fileId] = offset;
                  },
                  onRemoteTransferDeclined: handleRemoteTransferDeclined,
                );
              },
              onError: (error) {},
            );
          } else if (command['mode'] == 'client') {
            SecurityContext? securityContext;
            final expectedCertificateFingerprint =
                command['expectedCertificateFingerprint'] as String?;
            if (useTLS) {
              try {
                final certPath = command['certPath'] as String?;
                final keyPath = command['keyPath'] as String?;
                final trustedCertPath = command['trustedCertPath'] as String?;
                // A pre-trusted peer certificate is optional: when absent the
                // default context is used and the self-signed peer certificate
                // is accepted by onBadCertificate after matching
                // expectedCertificateFingerprint.
                if (trustedCertPath != null &&
                    File(trustedCertPath).existsSync()) {
                  securityContext = SecurityContext(withTrustedRoots: false);
                  securityContext.setTrustedCertificates(trustedCertPath);
                }
                if (certPath != null &&
                    keyPath != null &&
                    File(certPath).existsSync() &&
                    File(keyPath).existsSync()) {
                  securityContext ??= SecurityContext(withTrustedRoots: false);
                  securityContext.useCertificateChain(certPath);
                  securityContext.usePrivateKey(keyPath);
                }
              } catch (e) {
                rethrow;
              }
            }

            try {
              dynamic finalSocket;

              if (useTLS) {
                final rawSocket = await Socket.connect(
                  command['host'],
                  command['port'],
                );
                finalSocket = await SecureSocket.secure(
                  rawSocket,
                  host: TlsIdentityService.certificateCommonName,
                  context: securityContext,
                  onBadCertificate: (certificate) {
                    if (expectedCertificateFingerprint == null) {
                      return false;
                    }

                    final actualFingerprint =
                        TlsIdentityService.certificateFingerprint(
                          certificate.pem,
                        );
                    return actualFingerprint == expectedCertificateFingerprint;
                  },
                );
                final peerCertificate = finalSocket.peerCertificate;
                if (expectedCertificateFingerprint != null &&
                    peerCertificate != null) {
                  final actualFingerprint =
                      TlsIdentityService.certificateFingerprint(
                        peerCertificate.pem,
                      );
                  if (actualFingerprint != expectedCertificateFingerprint) {
                    throw Exception(
                      'The receiver TLS certificate fingerprint did not match discovery.',
                    );
                  }
                }
                core.configureSocketForTransfer(finalSocket);
                clientSocket = finalSocket;
                toUiSendPort.send({'status': 'connected_to_host'});
                _handleSocketConnection(
                  clientSocket!,
                  toUiSendPort,
                  getDownloadDirectory: () => currentDownloadDirectory,
                  shouldSuppressConnectionErrors: () =>
                      localDisconnectRequested,
                  shouldCancelReceivingFile: (fileId) =>
                      locallyCancelledTransfers.contains(fileId),
                  localPeerInfo: localPeerInfo,
                  onRemoteTransferPaused: handleRemoteTransferPaused,
                  onRemoteTransferResumed: handleRemoteTransferResumed,
                  onRemoteTransferCancelled: handleRemoteTransferCancelled,
                  onRemoteTransferAccepted: handleRemoteTransferAccepted,
                  onRemoteTransferOffset: (fileId, offset) {
                    remoteResumeOffsets[fileId] = offset;
                  },
                  onRemoteTransferDeclined: handleRemoteTransferDeclined,
                  onTransferAcknowledged: (fileId) {
                    if (sendingFileId == fileId) {
                      sendingFileId = null;
                    }
                  },
                );
              } else {
                // Non-TLS: send probe, then hand off to _handleSocketConnection
                // which handles both the probe response and subsequent file transfers
                finalSocket = await Socket.connect(
                  command['host'],
                  command['port'],
                );
                core.configureSocketForTransfer(finalSocket);
                final probeMsg = jsonEncode({'type': 'probe', 'tls': false});
                final probeBytes = utf8.encode(probeMsg);
                final header = ByteData(8);
                header.setUint32(0, probeBytes.length, Endian.big);
                header.setUint32(4, 0, Endian.big);
                finalSocket.add(header.buffer.asUint8List());
                finalSocket.add(probeBytes);

                clientSocket = finalSocket;
                // _handleSocketConnection will process the probe response as the
                // first incoming message and send 'connected_to_host' when verified
                _handleSocketConnection(
                  clientSocket!,
                  toUiSendPort,
                  waitForProbe: true,
                  getDownloadDirectory: () => currentDownloadDirectory,
                  shouldSuppressConnectionErrors: () =>
                      localDisconnectRequested,
                  shouldCancelReceivingFile: (fileId) =>
                      locallyCancelledTransfers.contains(fileId),
                  localPeerInfo: localPeerInfo,
                  onRemoteTransferPaused: handleRemoteTransferPaused,
                  onRemoteTransferResumed: handleRemoteTransferResumed,
                  onRemoteTransferCancelled: handleRemoteTransferCancelled,
                  onRemoteTransferAccepted: handleRemoteTransferAccepted,
                  onRemoteTransferOffset: (fileId, offset) {
                    remoteResumeOffsets[fileId] = offset;
                  },
                  onRemoteTransferDeclined: handleRemoteTransferDeclined,
                  onTransferAcknowledged: (fileId) {
                    if (sendingFileId == fileId) {
                      sendingFileId = null;
                    }
                  },
                );
              }
            } catch (e) {
              toUiSendPort.send({
                'status': 'error',
                'fatal': 'true',
                'message': core.clientConnectErrorMessage(
                  error: e,
                  host: command['host'] as String?,
                  port: command['port'] as int?,
                  useTLS: useTLS,
                ),
              });
            }
          }
        } else if (command['command'] == 'send_file' ||
            command['command'] == 'send_file_separate') {
          if (localDisconnectRequested) {
            continue;
          }
          if (clientSocket == null) {
            toUiSendPort.send({
              'status': 'error',
              'fatal': 'true',
              'message': 'Socket not connected',
            });
            continue;
          }

          final batch = <Map<String, dynamic>>[command];
          // 只有普通的 send_file 才合并成批量请求；send_file_separate 每个文件单独请求。
          if (command['command'] == 'send_file') {
            while (commandQueue.isNotEmpty &&
                commandQueue.first['command'] == 'send_file') {
              batch.add(commandQueue.removeFirst());
            }
          }

          try {
            isSendingFile = true;
            if (batch.length == 1) {
              sendingFileId = await _sendFileCommand(
                batch[0],
                clientSocket!,
                toUiSendPort,
                shouldCancel: () => localDisconnectRequested,
                shouldPauseTransfer: isTransferPaused,
                shouldCancelTransfer: (fileId) =>
                    locallyCancelledTransfers.contains(fileId) ||
                    remotelyCancelledTransfers.contains(fileId),
                shouldAcceptTransfer: (fileId) =>
                    acceptedTransfers.contains(fileId),
                shouldDeclineTransfer: (fileId) =>
                    declinedTransfers.contains(fileId),
                resumeOffsetFor: (fileId) =>
                    remoteResumeOffsets[fileId] ?? 0,
                onPaused: (fileId) async {
                  final role = locallyPausedTransfers[fileId];
                  if (role == null) {
                    return;
                  }
                  await core.sendSocketFrame(clientSocket, {
                    'type': transferControlType(role, 'paused'),
                    'fileId': fileId,
                  });
                },
              );
            } else {
              sendingFileId = await _sendBatchCommand(
                batch,
                clientSocket!,
                toUiSendPort,
                shouldCancel: () => localDisconnectRequested,
                shouldPauseTransfer: isTransferPaused,
                shouldCancelTransfer: (fileId) =>
                    locallyCancelledTransfers.contains(fileId) ||
                    remotelyCancelledTransfers.contains(fileId),
                shouldAcceptTransfer: (fileId) =>
                    acceptedTransfers.contains(fileId),
                shouldDeclineTransfer: (fileId) =>
                    declinedTransfers.contains(fileId),
                onPaused: (fileId) async {
                  final role = locallyPausedTransfers[fileId];
                  if (role == null) {
                    return;
                  }
                  await core.sendSocketFrame(clientSocket, {
                    'type': transferControlType(role, 'paused'),
                    'fileId': fileId,
                  });
                },
              );
            }
            if (sendingFileId != null) {
              locallyPausedTransfers.remove(sendingFileId);
              remotelyPausedTransfers.remove(sendingFileId);
              locallyCancelledTransfers.remove(sendingFileId);
              remotelyCancelledTransfers.remove(sendingFileId);
              acceptedTransfers.remove(sendingFileId);
              declinedTransfers.remove(sendingFileId);
            }
          } on core.TransferCancelled {
            sendingFileId = null;
          } finally {
            isSendingFile = false;
          }
        } else if (command['command'] == 'pause_transfer') {
          final fileId = command['fileId'] as String?;
          final role = command['role'] as String? ?? 'receiver';
          if (fileId != null) {
            locallyPausedTransfers[fileId] = role;
            await core.sendSocketFrame(clientSocket, {
              'type': transferControlType(role, 'paused'),
              'fileId': fileId,
            });
            sendTransferPausedState(fileId);
          }
        } else if (command['command'] == 'resume_transfer') {
          final fileId = command['fileId'] as String?;
          final role = command['role'] as String? ?? 'receiver';
          if (fileId != null) {
            locallyPausedTransfers.remove(fileId);
            await core.sendSocketFrame(clientSocket, {
              'type': transferControlType(role, 'resumed'),
              'fileId': fileId,
            });
            sendTransferResumeState(fileId);
          }
        } else if (command['command'] == 'cancel_transfer') {
          final fileId = command['fileId'] as String?;
          if (fileId != null) {
            locallyCancelledTransfers.add(fileId);
            locallyPausedTransfers.remove(fileId);
            remotelyPausedTransfers.remove(fileId);
            await core.sendSocketFrame(clientSocket, {
              'type': 'file_transfer_cancel',
              'fileId': fileId,
            });
            toUiSendPort.send({
              'status': 'transfer_cancelled',
              'fileId': fileId,
            });
          }
        } else if (command['command'] == 'accept_transfer') {
          final fileId = command['fileId'] as String?;
          if (fileId != null) {
            acceptedTransfers.add(fileId);
            declinedTransfers.remove(fileId);
            await core.sendSocketFrame(clientSocket, {
              'type': 'file_transfer_accept',
              'fileId': fileId,
            });
            toUiSendPort.send({
              'status': 'transfer_accepted',
              'fileId': fileId,
            });
          }
        } else if (command['command'] == 'decline_transfer') {
          final fileId = command['fileId'] as String?;
          if (fileId != null) {
            declinedTransfers.add(fileId);
            locallyCancelledTransfers.add(fileId);
            await core.sendSocketFrame(clientSocket, {
              'type': 'file_transfer_decline',
              'fileId': fileId,
            });
            toUiSendPort.send({
              'status': 'transfer_cancelled',
              'fileId': fileId,
            });
            toUiSendPort.send({
              'status': 'transfer_cancel_ready',
              'fileId': fileId,
            });
          }
        } else if (command['command'] == "disconnect") {
          final wasSendingFile = isSendingFile;
          localDisconnectRequested = true;
          try {
            if (clientSocket != null) {
              await core.sendControlFrame(clientSocket, {
                'type': 'disconnect',
                'reason': wasSendingFile
                    ? 'transfer_cancelled'
                    : 'user_left',
              });
            }
          } catch (_) {}
          try {
            clientSocket?.destroy();
            await serverSocket?.close();
          } catch (_) {}
          toUiSendPort.send({'command': 'disconnect'});
        } else if (command['command'] == 'set_download_directory') {
          final newDir = command['downloadDirectory'] as String?;
          currentDownloadDirectory = newDir;
        }
      } catch (e) {
        if (localDisconnectRequested) {
          continue;
        }
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'false',
          'message': 'Command processing error: ${e.toString()}',
        });
      }
    }

    isProcessing = false;
  }

  fromUiReceivePort.listen((message) async {
    final command = message as Map<String, dynamic>;
    try {
    if (command['command'] == 'disconnect') {
      localDisconnectRequested = true;
      if (isSendingFile) {
        try {
          clientSocket?.destroy();
          serverSocket?.close();
        } catch (_) {}
      }
    } else if (command['command'] == 'pause_transfer') {
      final fileId = command['fileId'] as String?;
      final role = command['role'] as String? ?? 'receiver';
      if (fileId != null) {
        locallyPausedTransfers[fileId] = role;
        await core.sendSocketFrame(clientSocket, {
          'type': transferControlType(role, 'paused'),
          'fileId': fileId,
        });
        sendTransferPausedState(fileId);
        return;
      }
    } else if (command['command'] == 'resume_transfer') {
      final fileId = command['fileId'] as String?;
      final role = command['role'] as String? ?? 'receiver';
      if (fileId != null) {
        locallyPausedTransfers.remove(fileId);
        await core.sendSocketFrame(clientSocket, {
          'type': transferControlType(role, 'resumed'),
          'fileId': fileId,
        });
        sendTransferResumeState(fileId);
        return;
      }
    } else if (command['command'] == 'cancel_transfer') {
      final fileId = command['fileId'] as String?;
      if (fileId != null) {
        locallyCancelledTransfers.add(fileId);
        locallyPausedTransfers.remove(fileId);
        remotelyPausedTransfers.remove(fileId);
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_transfer_cancel',
          'fileId': fileId,
        });
        toUiSendPort.send({'status': 'transfer_cancelled', 'fileId': fileId});
        return;
      }
    } else if (command['command'] == 'accept_transfer') {
      final fileId = command['fileId'] as String?;
      if (fileId != null) {
        acceptedTransfers.add(fileId);
        declinedTransfers.remove(fileId);
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_transfer_accept',
          'fileId': fileId,
          'offset': _resumeOffsets[fileId] ?? 0,
        });
        toUiSendPort.send({'status': 'transfer_accepted', 'fileId': fileId});
        return;
      }
    } else if (command['command'] == 'decline_transfer') {
      final fileId = command['fileId'] as String?;
      if (fileId != null) {
        declinedTransfers.add(fileId);
        locallyCancelledTransfers.add(fileId);
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_transfer_decline',
          'fileId': fileId,
        });
        toUiSendPort.send({'status': 'transfer_cancelled', 'fileId': fileId});
        toUiSendPort.send({
          'status': 'transfer_cancel_ready',
          'fileId': fileId,
        });
        return;
      }
    } else if (command['command'] == 'cancel_outgoing_offer') {
      try {
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_offer_cancelled',
        });
      } finally {
        toUiSendPort.send({'status': 'outgoing_offer_cancelled'});
      }
      return;
    } else if (command['command'] == 'send_files') {
      final filePaths = command['filePaths'] as List<dynamic>;
      for (final path in filePaths) {
        commandQueue.add({'command': 'send_file', 'filePath': path as String});
      }
      processCommandQueue();
      return;
    } else if (command['command'] == 'send_files_separately') {
      // 逐个发送：每个文件都作为独立的单文件请求排队，不合并成批量请求。
      final filePaths = command['filePaths'] as List<dynamic>;
      for (final path in filePaths) {
        commandQueue.add({
          'command': 'send_file_separate',
          'filePath': path as String,
        });
      }
      processCommandQueue();
      return;
    } else if (command['command'] == 'cancel_queued_sends') {
      // 取消还没开始发送的排队文件；正在传的文件由 cancel_transfer 处理。
      final kept = commandQueue
          .where(
            (queued) =>
                queued['command'] != 'send_file' &&
                queued['command'] != 'send_file_separate',
          )
          .toList();
      commandQueue
        ..clear()
        ..addAll(kept);
      return;
    }
    commandQueue.add(command);
    processCommandQueue();
    } catch (e) {
      if (!localDisconnectRequested) {
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'false',
          'message': 'Command processing error: ${e.toString()}',
        });
      }
    }
  });
}

Future<String?> _sendFileCommand(
  Map<String, dynamic> command,
  dynamic clientSocket,
  SendPort toUiSendPort, {
  required bool Function() shouldCancel,
  required bool Function(String fileId) shouldPauseTransfer,
  required bool Function(String fileId) shouldCancelTransfer,
  required bool Function(String fileId) shouldAcceptTransfer,
  required bool Function(String fileId) shouldDeclineTransfer,
  required int Function(String fileId) resumeOffsetFor,
  Future<void> Function(String fileId)? onPaused,
}) async {
  final filePath = command['filePath'] as String;
  final displayName = command['displayName'] as String?;
  final clipboard = command['clipboard'] == true;
  File? fileToSend;
  Stream<List<int>>? chunksToSend;
  Map<String, dynamic>? fileHeader;

  final stopwatch = Stopwatch()..start();

  _SendSource? source;
  var fileStarted = false;

  try {
    if (Platform.isAndroid && filePath.startsWith('content://')) {
      source = await _openAndroidSendSource(Saf(), filePath);
      if (source == null) {
        throw Exception('Could not read selected file metadata.');
      }
      fileToSend = source.file;
      chunksToSend = source.chunks;

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': displayName ?? core.displayFileName(source.fileName),
        'size': source.fileSize,
      };
    } else {
      fileToSend = File(filePath);
      final fileStats = await fileToSend.stat();

      fileHeader = {
        'uuid': Uuid().v4(),
        'name': displayName ?? core.displayFileName(filePath),
        'size': fileStats.size,
      };
    }

    final fileId = fileHeader['uuid'] as String;
    final fileName = fileHeader['name'] as String;
    final fileSize = fileHeader['size'] as int;
    _sendingFileSizes[fileId] = fileSize;
    final resumeKey = sha1
        .convert(utf8.encode('$filePath|$fileName|$fileSize'))
        .toString();

    await core.sendSocketFrame(clientSocket, {
      'type': 'file_offer',
      'uuid': fileId,
      'name': fileName,
      'size': fileSize,
      'resumeKey': resumeKey,
      if (clipboard) 'clipboard': true,
    });

    toUiSendPort.send({
      'status': 'send_start',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'filePath': command['filePath'],
      'clipboard': clipboard,
      'pendingAcceptance': true,
    });

    while (!shouldCancel() &&
        !shouldCancelTransfer(fileId) &&
        !shouldDeclineTransfer(fileId) &&
        !shouldAcceptTransfer(fileId)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (shouldCancel() ||
        shouldCancelTransfer(fileId) ||
        shouldDeclineTransfer(fileId)) {
      throw const core.TransferCancelled();
    }

    final startOffset = resumeOffsetFor(fileId).clamp(0, fileSize).toInt();

    toUiSendPort.send({
      'status': 'send_start',
      'fileId': fileId,
      'fileName': fileName,
      'fileSize': fileSize,
      'filePath': command['filePath'],
      'resumeOffset': startOffset,
      'clipboard': clipboard,
      'pendingAcceptance': false,
    });

    await core.sendSocketFrame(clientSocket, {
      'type': 'file_start',
      'uuid': fileId,
      'name': fileName,
      'size': fileSize,
      'offset': startOffset,
      'resumeKey': resumeKey,
      if (clipboard) 'clipboard': true,
    });
    fileStarted = true;

    await _sendFileSequentially(
      fileId: fileId,
      file: fileToSend,
      chunks: chunksToSend,
      fileSize: fileSize,
      startOffset: startOffset,
      clientSocket: clientSocket,
      shouldCancel: shouldCancel,
      shouldPauseTransfer: shouldPauseTransfer,
      shouldCancelTransfer: shouldCancelTransfer,
      onPaused: onPaused,
      onProgress: (progress) {
        toUiSendPort.send({
          'status': 'send_progress',
          'fileId': fileId,
          'progress': progress.clamp(0.0, 0.999),
          'estimated': true,
        });
      },
    );
    await core.sendSocketFrame(clientSocket, {
      'type': 'file_end',
      'fileId': fileId,
      'size': fileSize,
    });
    await clientSocket.flush();

    stopwatch.stop();

    await source?.dispose();
    return fileId;
  } catch (e) {
    stopwatch.stop();
    await source?.dispose();
    if (e is core.TransferCancelled ||
        shouldCancel() ||
        (fileHeader != null &&
            shouldCancelTransfer(fileHeader['uuid'] as String))) {
      if (fileHeader != null) {
        if (!fileStarted) {
          toUiSendPort.send({
            'status': 'transfer_cancelled',
            'fileId': fileHeader['uuid'],
          });
          toUiSendPort.send({
            'status': 'transfer_cancel_ready',
            'fileId': fileHeader['uuid'],
          });
          return fileHeader['uuid'] as String;
        }
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_end',
          'fileId': fileHeader['uuid'],
          'cancelled': true,
        });
        toUiSendPort.send({
          'status': 'transfer_cancelled',
          'fileId': fileHeader['uuid'],
        });
        toUiSendPort.send({
          'status': 'transfer_cancel_ready',
          'fileId': fileHeader['uuid'],
        });
        return fileHeader['uuid'] as String;
      }
      return null;
    }
    toUiSendPort.send({
      'status': 'error',
      'fatal': 'false',
      'message': 'File send error: ${e.toString()}',
    });
    rethrow;
  }
}

Future<String?> _sendBatchCommand(
  List<Map<String, dynamic>> batch,
  dynamic clientSocket,
  SendPort toUiSendPort, {
  required bool Function() shouldCancel,
  required bool Function(String fileId) shouldPauseTransfer,
  required bool Function(String fileId) shouldCancelTransfer,
  required bool Function(String fileId) shouldAcceptTransfer,
  required bool Function(String fileId) shouldDeclineTransfer,
  Future<void> Function(String fileId)? onPaused,
}) async {
  final fileEntries = <_FileEntry>[];

  for (final command in batch) {
    final filePath = command['filePath'] as String;

    try {
      if (Platform.isAndroid && filePath.startsWith('content://')) {
        final source = await _openAndroidSendSource(Saf(), filePath);
        if (source == null) {
          continue;
        }
        fileEntries.add(
          _FileEntry(
            source: source,
            header: {
              'uuid': Uuid().v4(),
              'name': core.displayFileName(source.fileName),
              'size': source.fileSize,
            },
            filePath: filePath,
          ),
        );
      } else {
        final fileToSend = File(filePath);
        final fileStats = await fileToSend.stat();
        fileEntries.add(
          _FileEntry(
            source: _SendSource(
              file: fileToSend,
              fileName: core.displayFileName(filePath),
              fileSize: fileStats.size,
            ),
            header: {
              'uuid': Uuid().v4(),
              'name': core.displayFileName(filePath),
              'size': fileStats.size,
            },
            filePath: filePath,
          ),
        );
      }
    } on Exception catch (_) {
      continue;
    }
  }

  if (fileEntries.isEmpty) return null;

  final filesJson = fileEntries
      .map(
        (e) => {
          'uuid': e.header['uuid'],
          'name': e.header['name'],
          'size': e.header['size'],
        },
      )
      .toList();

  await core.sendSocketFrame(clientSocket, {
    'type': 'file_batch',
    'files': filesJson,
  });

  for (final entry in fileEntries) {
    toUiSendPort.send({
      'status': 'send_start',
      'fileId': entry.header['uuid'],
      'fileName': entry.header['name'],
      'fileSize': entry.header['size'],
      'filePath': entry.filePath,
      'pendingAcceptance': true,
      'isBatch': true,
    });
  }

  final firstFileId = fileEntries.first.header['uuid'] as String;
  try {
    while (!shouldCancel() &&
        !shouldCancelTransfer(firstFileId) &&
        !shouldDeclineTransfer(firstFileId) &&
        !shouldAcceptTransfer(firstFileId)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (shouldCancel() ||
        shouldCancelTransfer(firstFileId) ||
        shouldDeclineTransfer(firstFileId)) {
      throw const core.TransferCancelled();
    }

    for (final entry in fileEntries) {
      final fileId = entry.header['uuid'] as String;
      final isFirst = entry == fileEntries.first;
      final isLast = entry == fileEntries.last;

      if (!isFirst) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      toUiSendPort.send({
        'status': 'send_start',
        'fileId': fileId,
        'fileName': entry.header['name'],
        'fileSize': entry.header['size'],
        'filePath': entry.filePath,
        'pendingAcceptance': false,
        'isBatch': true,
      });

      await core.sendSocketFrame(clientSocket, {
        'type': 'file_start',
        'uuid': fileId,
        'name': entry.header['name'],
        'size': entry.header['size'],
      });

      var fileCancelled = false;
      try {
        await _sendFileSequentially(
          fileId: fileId,
          file: entry.source.file,
          chunks: entry.source.chunks,
          fileSize: entry.header['size'] as int,
          startOffset: 0,
          clientSocket: clientSocket,
          shouldCancel: shouldCancel,
          shouldPauseTransfer: shouldPauseTransfer,
          shouldCancelTransfer: shouldCancelTransfer,
          onPaused: onPaused,
          onProgress: (progress) {
            toUiSendPort.send({
              'status': 'send_progress',
              'fileId': fileId,
              'progress': progress.clamp(0.0, 0.999),
              'estimated': true,
            });
          },
        );
      } on core.TransferCancelled {
        fileCancelled = true;
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_end',
          'fileId': fileId,
          'cancelled': true,
        });
        await clientSocket.flush();
        if (isLast) {
          toUiSendPort.send({
            'status': 'transfer_cancel_ready',
            'fileId': fileId,
          });
        }
      }

      if (!fileCancelled) {
        await core.sendSocketFrame(clientSocket, {
          'type': 'file_end',
          'fileId': fileId,
        });
        await clientSocket.flush();
      }

      await entry.source.dispose();

      if (shouldCancel()) {
        throw const core.TransferCancelled();
      }
    }

    return firstFileId;
  } catch (_) {
    for (final entry in fileEntries) {
      await entry.source.dispose();
    }
    rethrow;
  }
}

class _FileEntry {
  final _SendSource source;
  final Map<String, dynamic> header;
  final String filePath;

  const _FileEntry({
    required this.source,
    required this.header,
    required this.filePath,
  });
}

/// 一个待发送文件的读取来源，以及传输结束后要释放的资源。
///
/// content:// 文档要么能直接按文件描述符读（[file]），要么只能按块流式读
/// （[chunks]）；两者都不会把整个文件复制到缓存目录。
class _SendSource {
  const _SendSource({
    required this.fileName,
    required this.fileSize,
    this.file,
    this.chunks,
    this.fd,
  });

  final String fileName;
  final int fileSize;
  final File? file;
  final Stream<List<int>>? chunks;
  final int? fd;

  Future<void> dispose() async {
    final fd = this.fd;
    if (fd != null) {
      try {
        await Saf().closeFileDescriptor(fd);
      } on Exception catch (_) {}
    }
  }
}

/// 打开一个 Android SAF 文档作为发送来源。
///
/// [Saf.openFileDescriptor] 给出的 `/proc/self/fd/<fd>` 伪路径大多数设备能直接读；
/// 部分 OEM（例如 Realme UI 6 / Android 15）的 SELinux 策略会拒绝，此时退回按块
/// 流式读取（[Saf.readFileStream]），不再把整个文档复制到缓存——几 GB 的文件复制
/// 既会长时间卡住，也会占满缓存目录。
Future<_SendSource?> _openAndroidSendSource(Saf saf, String uri) async {
  final fileStats = await saf.stat(uri);
  if (fileStats == null) {
    return null;
  }
  final fileName = fileStats.name;
  final fileSize = fileStats.length;

  int? openedFd;
  try {
    final fdResult = await saf.openFileDescriptor(uri, 'r');
    openedFd = fdResult.fd;
    final pseudoFile = File(fdResult.path);
    final probe = await pseudoFile.open();
    await probe.close();
    return _SendSource(
      file: pseudoFile,
      fileName: fileName,
      fileSize: fileSize,
      fd: openedFd,
    );
  } catch (_) {
    if (openedFd != null) {
      try {
        await saf.closeFileDescriptor(openedFd);
      } on Exception catch (_) {}
    }
  }

  final chunks = await saf.readFileStream(uri);
  return _SendSource(
    fileName: fileName,
    fileSize: fileSize,
    chunks: chunks,
  );
}

Future<void> _sendFileSequentially({
  required String fileId,
  required File? file,
  required Stream<List<int>>? chunks,
  required int fileSize,
  required int startOffset,
  required dynamic clientSocket,
  required bool Function() shouldCancel,
  required bool Function(String fileId) shouldPauseTransfer,
  required bool Function(String fileId) shouldCancelTransfer,
  Future<void> Function(String fileId)? onPaused,
  void Function(double progress)? onProgress,
}) async {
  // 每次发送 1 MB：帧头、JSON 元数据和 flush 的开销按块数计，块太小会把
  // 大文件的吞吐压下来（64 KB 时每 MB 有 16 次编码 + 16 次 flush）。
  const int chunkSize = 1024 * 1024;
  if (fileSize <= 0 || startOffset >= fileSize) {
    return;
  }

  final chunkStream = chunks;
  if (chunkStream != null) {
    await _sendChunksSequentially(
      fileId: fileId,
      chunks: chunkStream,
      fileSize: fileSize,
      startOffset: startOffset,
      clientSocket: clientSocket,
      shouldCancel: shouldCancel,
      shouldPauseTransfer: shouldPauseTransfer,
      shouldCancelTransfer: shouldCancelTransfer,
      onPaused: onPaused,
      onProgress: onProgress,
    );
    return;
  }

  final raf = await file!.open();
  try {
    final buffer = Uint8List(chunkSize);
    var position = startOffset;
    var lastPauseNoticeAt = DateTime.fromMillisecondsSinceEpoch(0);
    await raf.setPosition(startOffset);

    while (position < fileSize) {
      while (!shouldCancel() &&
          !shouldCancelTransfer(fileId) &&
          shouldPauseTransfer(fileId)) {
        final now = DateTime.now();
        if (onPaused != null &&
            now.difference(lastPauseNoticeAt) >=
                const Duration(milliseconds: 500)) {
          lastPauseNoticeAt = now;
          await onPaused(fileId);
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (shouldCancel() || shouldCancelTransfer(fileId)) {
        throw const core.TransferCancelled();
      }

      final bytesToRead = min(chunkSize, fileSize - position);
      final bytesRead = await raf.readInto(buffer, 0, bytesToRead);
      if (bytesRead <= 0) {
        break;
      }
      final actualChunk = Uint8List.sublistView(buffer, 0, bytesRead);

      await core.sendSocketFrame(
        clientSocket,
        {
          'type': 'file_chunk',
          'fileId': fileId,
        },
        payloadBytes: actualChunk,
      );
      if (shouldCancel() || shouldCancelTransfer(fileId)) {
        throw const core.TransferCancelled();
      }
      position += bytesRead;
      onProgress?.call(fileSize == 0 ? 1.0 : position / fileSize);
    }
  } finally {
    await raf.close();
  }
}

/// 按块读取文档并逐块发送，用于不能直接读文件描述符的 content:// 文档。
///
/// 暂停时不再拉取下一块（`await for` 会暂停底层订阅，读取端随之减速），取消时
/// 抛出 [core.TransferCancelled]，`await for` 会关闭底层读取流。
Future<void> _sendChunksSequentially({
  required String fileId,
  required Stream<List<int>> chunks,
  required int fileSize,
  required int startOffset,
  required dynamic clientSocket,
  required bool Function() shouldCancel,
  required bool Function(String fileId) shouldPauseTransfer,
  required bool Function(String fileId) shouldCancelTransfer,
  Future<void> Function(String fileId)? onPaused,
  void Function(double progress)? onProgress,
}) async {
  // 文档流每次给的数据量不定（常见 8~64 KB），攒到 1 MB 再发，减少帧数与 flush 次数。
  const int sendBatchBytes = 1024 * 1024;
  var lastPauseNoticeAt = DateTime.fromMillisecondsSinceEpoch(0);
  final pending = BytesBuilder(copy: false);
  var remainingSkip = startOffset;
  var sentBytes = startOffset;

  Future<void> flushPending() async {
    if (pending.isEmpty) {
      return;
    }
    final chunk = pending.takeBytes();
    await core.sendSocketFrame(
      clientSocket,
      {
        'type': 'file_chunk',
        'fileId': fileId,
      },
      payloadBytes: chunk,
    );
    sentBytes += chunk.length;
    onProgress?.call(fileSize == 0 ? 1.0 : sentBytes / fileSize);
  }

  try {
    await for (final originalChunk in chunks) {
      if (originalChunk.isEmpty) {
        continue;
      }
      var rawChunk = originalChunk;
      if (remainingSkip > 0) {
        if (rawChunk.length <= remainingSkip) {
          remainingSkip -= rawChunk.length;
          continue;
        }
        rawChunk = rawChunk.sublist(remainingSkip);
        remainingSkip = 0;
      }
      while (!shouldCancel() &&
          !shouldCancelTransfer(fileId) &&
          shouldPauseTransfer(fileId)) {
        final now = DateTime.now();
        if (onPaused != null &&
            now.difference(lastPauseNoticeAt) >=
                const Duration(milliseconds: 500)) {
          lastPauseNoticeAt = now;
          await onPaused(fileId);
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (shouldCancel() || shouldCancelTransfer(fileId)) {
        throw const core.TransferCancelled();
      }

      pending.add(rawChunk is Uint8List ? rawChunk : Uint8List.fromList(rawChunk));
      if (pending.length >= sendBatchBytes) {
        await flushPending();
      }
    }
    await flushPending();
  } finally {
    // 取消时丢掉还没发出的数据，不把半截缓冲写出去。
    pending.clear();
  }
}

void _handleSocketConnection(
  dynamic socket,
  SendPort toUiSendPort, {
  bool waitForProbe = false,
  String? Function()? getDownloadDirectory,
  bool Function()? shouldSuppressConnectionErrors,
  bool Function(String fileId)? shouldCancelReceivingFile,
  void Function(String fileId)? onTransferAcknowledged,
  void Function(String fileId, {String? pausedBy})? onRemoteTransferPaused,
  void Function(String fileId, {String? pausedBy})? onRemoteTransferResumed,
  void Function(String fileId)? onRemoteTransferCancelled,
  void Function(String fileId)? onRemoteTransferAccepted,
  void Function(String fileId, int offset)? onRemoteTransferOffset,
  void Function(String fileId)? onRemoteTransferDeclined,
  required Map<String, dynamic> localPeerInfo,
}) {
  final readBuffer = core.SocketReadBuffer();
  const progressUpdateInterval = Duration(milliseconds: 500);

  int? fileBytesLength;
  int bytesWritten = 0;
  int lastProgressPercent = -1;
  int? chunkBytesRemaining;
  bool isChunkedFileFrame = false;
  bool isDiscardingCancelledFile = false;
  // A socket loss is not the same as a cancelled transfer: keep the partial
  // file so the next connection can resume instead of starting over.
  bool preservePartialOnDisconnect = false;
  DateTime lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  core.OutputTarget? activeOutputTarget;
  Map<String, dynamic>? activeFileHeader;

  final Stopwatch stopwatch = Stopwatch();

  bool probeHandled = !waitForProbe;
  bool connectionErrorSent = false;
  bool gracefulDisconnect = false;
  bool socketClosed = false;

  // 最近一次收到对端数据的时间；心跳据此判断链路是否还活着。
  var lastInboundAt = DateTime.now();
  final localUsesTls = localPeerInfo['tls'] == true;

  Future<void> cleanupOpenFile() async {
    await activeOutputTarget?.closeWriter();
  }

  void resetFrameState() {
    fileBytesLength = null;
    activeFileHeader = null;
    bytesWritten = 0;
    lastProgressPercent = -1;
    chunkBytesRemaining = null;
    isChunkedFileFrame = false;
    isDiscardingCancelledFile = false;
    preservePartialOnDisconnect = false;
  }

  /// Closes the writer but leaves the partial file on disk for a later resume.
  Future<void> preservePartialOutput() async {
    final target = activeOutputTarget;
    if (target == null) {
      resetFrameState();
      return;
    }

    try {
      if (activeFileHeader?['clipboard'] != true) {
        await target.closeWriter();
      }
    } catch (_) {
      // The file is already unusable; deletePartialOutput is used for that path.
    }

    activeOutputTarget = null;
    resetFrameState();
  }

  Future<void> discardPartialOutput() async {
    final target = activeOutputTarget;
    if (target == null) {
      return;
    }

    // 粘贴板内容只在传输完整时写回，丢弃半截内容时不能触发 closeWriter。
    if (activeFileHeader?['clipboard'] != true) {
      await target.closeWriter();
    }
    await target.deleteFile();

    activeOutputTarget = null;
    resetFrameState();
  }

  Future<void> discardActiveOutputForCancel() async {
    final target = activeOutputTarget;
    if (target != null) {
      if (activeFileHeader?['clipboard'] != true) {
        await target.closeWriter();
      }
      await target.deleteFile();
    }

    activeOutputTarget = null;
  }

  void sendControlFrame(Map<String, dynamic> payload) {
    // All frames share one per-socket writer, so a heartbeat waits for the
    // in-flight file chunk instead of hitting a bound sink.
    unawaited(
      core.sendControlFrame(socket, payload).catchError((Object error) {
        debugPrint('[FRAME] sendControlFrame failed: $error');
      }),
    );
  }

  void sendLocalPeerInfo() {
    sendControlFrame(localPeerInfo);
  }

  void closeSocket() {
    if (socketClosed) {
      return;
    }
    socketClosed = true;
    socket.destroy();
  }

  void sendConnectionError(
    String message, {
    bool fatal = true,
    bool markProbeHandled = true,
  }) {
    if (connectionErrorSent) {
      return;
    }
    connectionErrorSent = true;
    if (markProbeHandled) {
      probeHandled = true;
    }
    // fatal 与其它错误消息保持字符串 'true'/'false'，界面按字符串判断是否致命。
    toUiSendPort.send({
      'status': 'error',
      'fatal': fatal ? 'true' : 'false',
      'message': message,
    });
  }

  String tlsHandshakeFailureMessage() {
    if (localUsesTls) {
      return 'This device has TLS enabled, but the other device appears to have TLS disabled. Disable TLS on this device, or enable TLS on the other device, then try again.';
    }

    return 'This device has TLS disabled, but the other device appears to require TLS. Enable TLS on this device, or disable TLS on the other device, then try again.';
  }

  void sendProgress({bool force = false}) {
    final totalBytes = fileBytesLength;
    final header = activeFileHeader;
    if (totalBytes == null || header == null) {
      return;
    }

    final progress = totalBytes == 0
        ? 1.0
        : (bytesWritten / totalBytes).clamp(0.0, 1.0);
    final percent = (progress * 100).floor();
    final now = DateTime.now();
    if (!force &&
        percent == lastProgressPercent &&
        now.difference(lastProgressUpdate) < progressUpdateInterval) {
      return;
    }
    if (!force &&
        percent < 100 &&
        now.difference(lastProgressUpdate) < progressUpdateInterval) {
      return;
    }

    lastProgressPercent = percent;
    lastProgressUpdate = now;
    toUiSendPort.send({
      'status': 'progress',
      'fileId': header['uuid'],
      'progress': progress,
    });
    sendControlFrame({
      'type': 'file_receive_progress',
      'fileId': header['uuid'],
      'progress': progress,
    });
  }

  Future<bool> handleControlFrame(Map<String, dynamic> headerJson) async {
    if (!probeHandled) {
      probeHandled = true;
      final ok = headerJson['ok'];
      if (ok != null) {
        if (ok == true) {
          sendLocalPeerInfo();
          toUiSendPort.send({'status': 'connected_to_host'});
          return true;
        }
        sendConnectionError(
          headerJson['error'] as String? ??
              'Could not establish the connection. Check the TLS setting on both devices.',
        );
        closeSocket();
        return false;
      }

      if (headerJson['type'] == 'probe') {
        final clientWantsTls = headerJson['tls'] == true;
        final response = clientWantsTls
            ? {
                'ok': false,
                'error':
                    'This device has TLS disabled, but the connecting device has TLS enabled. Enable TLS on this device, or ask the other device to disable TLS, then try again.',
              }
            : {'ok': true, 'tls': false};
        sendControlFrame(response);

        if (clientWantsTls) {
          sendConnectionError(
            'This device has TLS disabled, but the connecting device has TLS enabled. Enable TLS on this device, or ask the other device to disable TLS, then try again.',
            fatal: false,
          );
          closeSocket();
          return false;
        }

        sendLocalPeerInfo();
        toUiSendPort.send({'status': 'client_connected'});
        return true;
      }
    }

    switch (headerJson['type']) {
      case 'ping':
        sendControlFrame({'type': 'pong'});
        return true;
      case 'pong':
        return true;
      case 'peer_info':
        toUiSendPort.send({
          'status': 'peer_info',
          'name': headerJson['name'] is String
              ? headerJson['name']
              : 'Connected device',
          'deviceType': headerJson['deviceType'] == 'laptop'
              ? 'laptop'
              : 'phone',
          'port': headerJson['port'] is int ? headerJson['port'] : null,
          'tls': headerJson['tls'] == true,
          'certFingerprint': headerJson['certFingerprint'] is String
              ? headerJson['certFingerprint']
              : null,
          'address': socket.remoteAddress.address,
        });
        return true;
      case 'file_received_ack':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          final expectedSize = _sendingFileSizes.remove(fileId);
          final ackSize = (headerJson['size'] as num?)?.toInt();
          if (ackSize != null &&
              expectedSize != null &&
              ackSize != expectedSize) {
            toUiSendPort.send({
              'status': 'error',
              'fatal': 'true',
              'message':
                  'Received file size mismatch: expected $expectedSize bytes '
                  'but the receiver confirmed $ackSize bytes.',
            });
            closeSocket();
            return false;
          }
          onTransferAcknowledged?.call(fileId);
          toUiSendPort.send({
            'status': 'send_complete',
            'fileId': fileId,
            'fileName': headerJson['fileName'],
            'timeTaken': headerJson['timeTaken'],
          });
        }
        return true;
      case 'file_receive_progress':
        final fileId = headerJson['fileId'] as String?;
        final progress = (headerJson['progress'] as num?)?.toDouble();
        if (fileId != null && progress != null) {
          toUiSendPort.send({
            'status': 'send_progress',
            'fileId': fileId,
            'progress': progress.clamp(0.0, 1.0),
          });
        }
        return true;
      case 'file_offer':
        final fileId = headerJson['uuid'] as String?;
        final fileName = headerJson['name'] as String?;
        final fileSize = headerJson['size'] as int?;
        if (fileId != null && fileName != null && fileSize != null) {
          final resumeKey = headerJson['resumeKey'] as String? ?? '';
          final resumeOffset = await _partialSizeFor(
            configuredDownloadDirectory: getDownloadDirectory?.call(),
            resumeKey: resumeKey,
          );
          if (resumeOffset > 0) {
            _resumeOffsets[fileId] = resumeOffset
                .clamp(0, fileSize)
                .toInt();
          }
          toUiSendPort.send({
            'status': 'start',
            'fileId': fileId,
            'fileName': core.displayFileName(fileName),
            'filePath': '',
            'fileSize': fileSize,
            'resumeOffset': resumeOffset.clamp(0, fileSize),
            'pendingAcceptance': true,
            'clipboard': headerJson['clipboard'] == true,
          });
        }
        return true;
      case 'file_batch':
        final files = headerJson['files'] as List<dynamic>?;
        if (files != null && files.isNotEmpty) {
          final fileList = files.map((f) {
            return <String, dynamic>{
              'fileId': f['uuid'] as String,
              'fileName': core.displayFileName(f['name'] as String),
              'fileSize': f['size'] as int,
            };
          }).toList();
          toUiSendPort.send({
            'status': 'start',
            'files': fileList,
            'pendingAcceptance': true,
            'isBatch': true,
          });
        }
        return true;
      case 'file_transfer_accept':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          final offset = (headerJson['offset'] as num?)?.toInt() ?? 0;
          onRemoteTransferOffset?.call(fileId, offset);
          onRemoteTransferAccepted?.call(fileId);
        }
        return true;
      case 'file_transfer_decline':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          onRemoteTransferDeclined?.call(fileId);
        }
        return true;
      case 'file_offer_cancelled':
        gracefulDisconnect = true;
        toUiSendPort.send({'status': 'offer_cancelled_by_sender'});
        return true;
      case 'sender_paused':
      case 'receiver_paused':
      case 'file_transfer_pause':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          final frameType = headerJson['type'] as String?;
          final pausedBy = switch (frameType) {
            'sender_paused' => 'sender',
            'receiver_paused' => 'receiver',
            _ => null,
          };
          onRemoteTransferPaused?.call(fileId, pausedBy: pausedBy);
        }
        return true;
      case 'sender_resumed':
      case 'receiver_resumed':
      case 'file_transfer_resume':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          final frameType = headerJson['type'] as String?;
          final pausedBy = switch (frameType) {
            'sender_resumed' => 'sender',
            'receiver_resumed' => 'receiver',
            _ => null,
          };
          onRemoteTransferResumed?.call(fileId, pausedBy: pausedBy);
        }
        return true;
      case 'file_transfer_cancel':
        final fileId = headerJson['fileId'] as String?;
        if (fileId != null) {
          onRemoteTransferCancelled?.call(fileId);
          if (activeFileHeader?['uuid'] == fileId) {
            isDiscardingCancelledFile = true;
            await discardActiveOutputForCancel();
          }
        }
        return true;
      case 'disconnect':
        gracefulDisconnect = true;
        await discardPartialOutput();
        closeSocket();
        toUiSendPort.send({'command': 'disconnect'});
        return false;
    }

    return false;
  }

  /// 粘贴板接收目标：内容只留在内存里，关闭时写回系统粘贴板，不生成磁盘文件。
  core.OutputTarget createClipboardOutputTarget({required String fileName}) {
    final bytes = <int>[];
    return core.OutputTarget.custom(
      fileName: fileName,
      filePath: '',
      writeChunk: (chunk) => bytes.addAll(chunk),
      closeWriter: () async {
        final text = utf8.decode(bytes, allowMalformed: true);
        await Clipboard.setData(ClipboardData(text: text));
      },
      deleteFile: () async {},
    );
  }

  Future<void> beginFileFrame(
    Map<String, dynamic> headerJson,
    int fileSize, {
    required bool chunked,
    required int startOffset,
    required String resumeKey,
  }) async {
    final fileName = headerJson['name'] as String;
    final isClipboard = headerJson['clipboard'] == true;
    final offeredFileId = headerJson['uuid'] as String?;
    if (offeredFileId != null) {
      _resumeOffsets.remove(offeredFileId);
    }
    if (startOffset < 0 || startOffset > fileSize) {
      sendConnectionError(
        'Invalid resume offset $startOffset for a $fileSize byte file.',
      );
      closeSocket();
      return;
    }
    // A previous connection may still be closing its partial file.
    await _pendingReceiveCleanup.catchError((_) {});
    core.OutputTarget? fileTarget;
    if (isClipboard) {
      fileTarget = createClipboardOutputTarget(
        fileName: core.displayFileName(fileName),
      );
    } else {
      try {
        fileTarget = await _createOutputTarget(
          configuredDownloadDirectory: getDownloadDirectory?.call(),
          originalFileName: core.displayFileName(fileName),
          resumeKey: resumeKey,
          startOffset: startOffset,
          onWriteError: (e) {
            preservePartialOnDisconnect = false;
            connectionErrorSent = true;
            toUiSendPort.send({
              'status': 'error',
              'fatal': 'true',
              'message': 'Could not save received file: ${e.toString()}',
            });
            closeSocket();
          },
        );
      } catch (e) {
        connectionErrorSent = true;
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'true',
          'message': 'Could not prepare file for download: ${e.toString()}',
        });
        closeSocket();
        return;
      }
    }
    activeOutputTarget = fileTarget;
    activeFileHeader = headerJson;
    fileBytesLength = fileSize;
    isChunkedFileFrame = chunked;
    bytesWritten = startOffset;
    preservePartialOnDisconnect = !isClipboard;
    lastProgressPercent = -1;
    stopwatch
      ..reset()
      ..start();

    toUiSendPort.send({
      'status': 'start',
      'fileId': headerJson['uuid'],
      'fileName': fileTarget.fileName,
      'filePath': fileTarget.filePath,
      'fileSize': fileSize,
      'resumeOffset': startOffset,
      'clipboard': isClipboard,
    });
  }

  Future<void> completeFileFrame() async {
    final target = activeOutputTarget!;
    final header = activeFileHeader!;
    final timeTaken = stopwatch.elapsed.inSeconds.toString();

    // Close and finalize before acknowledging: the sender must not be told the
    // file is complete while the receiver is still flushing or renaming it.
    try {
      await target.closeWriter();
      final finalize = target.finalizeFile;
      if (finalize != null) {
        await finalize();
      }
    } catch (e) {
      connectionErrorSent = true;
      toUiSendPort.send({
        'status': 'error',
        'fatal': 'true',
        'message': header['clipboard'] == true
            ? 'Could not write the clipboard text: ${e.toString()}'
            : 'Could not save received file: ${e.toString()}',
      });
      stopwatch.stop();
      activeOutputTarget = null;
      resetFrameState();
      closeSocket();
      return;
    }

    sendProgress(force: true);
    sendControlFrame({
      'type': 'file_received_ack',
      'fileId': header['uuid'],
      'fileName': target.fileName,
      'size': fileBytesLength,
      'timeTaken': timeTaken,
    });

    toUiSendPort.send({
      'status': 'completed',
      'fileId': header['uuid'],
      'timeTaken': timeTaken,
      'fileName': target.fileName,
      'filePath': target.filePath,
      'clipboard': header['clipboard'] == true,
    });

    stopwatch.stop();
    activeOutputTarget = null;
    resetFrameState();
  }

  Future<void> processBufferedFrames() async {
    while (!socketClosed) {
      final drainingCancelledFile =
          isDiscardingCancelledFile && activeFileHeader != null;
      if (activeOutputTarget == null && !drainingCancelledFile) {
        final frameHeader = readBuffer.tryPeekFrameHeader();
        if (frameHeader == null ||
            readBuffer.availableBytes < 8 + frameHeader.headerLength) {
          return;
        }

        readBuffer.skipBytes(8);
        final headerBytes = readBuffer.tryReadBytes(frameHeader.headerLength)!;
        final headerJson =
            jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;

        final frameType = headerJson['type'] as String?;
        final isControlFrame =
            headerJson.containsKey('type') || headerJson.containsKey('ok');
        if (frameHeader.payloadLength == 0 && isControlFrame) {
          if (frameType == 'file_start') {
            final fileSize = headerJson['size'] as int?;
            if (fileSize == null) {
              continue;
            }
            await beginFileFrame(
              headerJson,
              fileSize,
              chunked: true,
              startOffset: (headerJson['offset'] as num?)?.toInt() ?? 0,
              resumeKey: headerJson['resumeKey'] as String? ?? '',
            );
            continue;
          }
          final keepReading = await handleControlFrame(headerJson);
          if (!keepReading) {
            return;
          }
          continue;
        }

        if (frameType == 'file_chunk') {
          if (readBuffer.availableBytes < frameHeader.payloadLength) {
            return;
          }
          readBuffer.skipBytes(frameHeader.payloadLength);
          continue;
        }

        await beginFileFrame(
          headerJson,
          frameHeader.payloadLength,
          chunked: false,
          startOffset: 0,
          resumeKey: '',
        );
      }

      final target = activeOutputTarget;
      final totalBytes = fileBytesLength;
      if ((!isDiscardingCancelledFile && target == null) ||
          totalBytes == null) {
        continue;
      }

      final activeFileId = activeFileHeader?['uuid'] as String?;
      if (activeFileId != null &&
          (shouldCancelReceivingFile?.call(activeFileId) ?? false) &&
          !isDiscardingCancelledFile) {
        isDiscardingCancelledFile = true;
        await discardActiveOutputForCancel();
      }

      if (isChunkedFileFrame) {
        if (chunkBytesRemaining == null) {
          final frameHeader = readBuffer.tryPeekFrameHeader();
          if (frameHeader == null ||
              readBuffer.availableBytes < 8 + frameHeader.headerLength) {
            return;
          }

          readBuffer.skipBytes(8);
          final headerBytes = readBuffer.tryReadBytes(
            frameHeader.headerLength,
          )!;
          final headerJson =
              jsonDecode(utf8.decode(headerBytes)) as Map<String, dynamic>;
          final frameType = headerJson['type'] as String?;

          if (frameHeader.payloadLength == 0) {
            if (frameType == 'file_start' && isDiscardingCancelledFile) {
              final fileSize = headerJson['size'] as int?;
              resetFrameState();
              if (fileSize != null) {
                await beginFileFrame(
                  headerJson,
                  fileSize,
                  chunked: true,
                  startOffset: 0,
                  resumeKey: '',
                );
              }
              continue;
            }
            if (frameType == 'file_end') {
              final wasCancelled = headerJson['cancelled'] == true;
              if (!isDiscardingCancelledFile && !wasCancelled) {
                final expectedSize =
                    headerJson['size'] as int? ?? fileBytesLength;
                if (expectedSize == null || bytesWritten != expectedSize) {
                  final received = bytesWritten;
                  await discardPartialOutput();
                  sendConnectionError(
                    'File transfer incomplete: received $received of '
                    '${expectedSize ?? '?'} bytes.',
                  );
                  closeSocket();
                  return;
                }
                await completeFileFrame();
              } else {
                final cancelledFileId =
                    (activeFileHeader?['uuid'] ?? headerJson['fileId'])
                        as String?;
                final shouldReportCancellation =
                    wasCancelled && !isDiscardingCancelledFile;
                if (wasCancelled && !isDiscardingCancelledFile) {
                  isDiscardingCancelledFile = true;
                  await discardActiveOutputForCancel();
                }
                if (cancelledFileId != null) {
                  if (shouldReportCancellation) {
                    toUiSendPort.send({
                      'status': 'transfer_cancelled',
                      'fileId': cancelledFileId,
                    });
                  }
                  toUiSendPort.send({
                    'status': 'transfer_cancel_ready',
                    'fileId': cancelledFileId,
                  });
                }
                resetFrameState();
              }
              continue;
            }

            final keepReading = await handleControlFrame(headerJson);
            if (!keepReading) {
              return;
            }
            continue;
          }

          if (frameType != 'file_chunk') {
            if (readBuffer.availableBytes < frameHeader.payloadLength) {
              return;
            }
            readBuffer.skipBytes(frameHeader.payloadLength);
            continue;
          }

          final chunkFileId = headerJson['fileId'] as String?;
          if (chunkFileId != activeFileId) {
            if (readBuffer.availableBytes < frameHeader.payloadLength) {
              return;
            }
            readBuffer.skipBytes(frameHeader.payloadLength);
            continue;
          }

          chunkBytesRemaining = frameHeader.payloadLength;
        }

        final remainingChunkBytes = chunkBytesRemaining!;
        if (remainingChunkBytes <= 0) {
          chunkBytesRemaining = null;
          continue;
        }

        final availableToDrain = min(
          remainingChunkBytes,
          readBuffer.availableBytes,
        );
        if (availableToDrain == 0) {
          return;
        }

        if (isDiscardingCancelledFile) {
          readBuffer.skipBytes(availableToDrain);
        } else {
          final chunk = readBuffer.tryReadBytes(availableToDrain)!;
          target!.writeChunk(chunk);
          bytesWritten += chunk.length;
          sendProgress();
        }
        chunkBytesRemaining = remainingChunkBytes - availableToDrain;
        if (chunkBytesRemaining == 0) {
          chunkBytesRemaining = null;
        }
        continue;
      }

      final remainingBytes = totalBytes - bytesWritten;
      if (remainingBytes <= 0) {
        await completeFileFrame();
        continue;
      }

      if (isDiscardingCancelledFile) {
        final skipBytes = min(remainingBytes, readBuffer.availableBytes);
        if (skipBytes == 0) {
          return;
        }
        readBuffer.skipBytes(skipBytes);
        bytesWritten += skipBytes;
      } else {
        final chunk = readBuffer.tryReadBytes(
          min(remainingBytes, readBuffer.availableBytes),
        );
        if (chunk == null || chunk.isEmpty) {
          return;
        }
        target!.writeChunk(chunk);
        bytesWritten += chunk.length;
        sendProgress();
      }

      if (bytesWritten == totalBytes) {
        if (isDiscardingCancelledFile) {
          resetFrameState();
        } else {
          await completeFileFrame();
        }
      }
    }
  }

  if (waitForProbe) {
    Future.delayed(const Duration(seconds: 5), () {
      if (!probeHandled && !(shouldSuppressConnectionErrors?.call() ?? false)) {
        sendConnectionError(tlsHandshakeFailureMessage());
        closeSocket();
      }
    });
  }

  if (!waitForProbe) {
    sendLocalPeerInfo();
  }

  late StreamSubscription<List<int>> subscription;
  subscription = socket.listen(
    (data) async {
      lastInboundAt = DateTime.now();
      subscription.pause();
      try {
        readBuffer.add(data);
        await processBufferedFrames();
      } finally {
        if (!socketClosed) {
          subscription.resume();
        }
      }
    },
    onDone: () {
      final preserve = preservePartialOnDisconnect;
      _pendingReceiveCleanup = activeOutputTarget == null
          ? cleanupOpenFile()
          : (preserve ? preservePartialOutput() : discardPartialOutput());
      unawaited(_pendingReceiveCleanup.catchError((_) {}));
      final suppressErrors = shouldSuppressConnectionErrors?.call() ?? false;
      if (suppressErrors) {
        gracefulDisconnect = true;
      }

      if (!probeHandled && !connectionErrorSent && !suppressErrors) {
        sendConnectionError(tlsHandshakeFailureMessage());
      } else if (!connectionErrorSent &&
          !gracefulDisconnect &&
          !suppressErrors) {
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'true',
          'message':
              'Connection lost. The other device disconnected unexpectedly.',
        });
      }
      closeSocket();
    },
    onError: (e, st) {
      final preserve = preservePartialOnDisconnect;
      _pendingReceiveCleanup = activeOutputTarget == null
          ? cleanupOpenFile()
          : (preserve ? preservePartialOutput() : discardPartialOutput());
      unawaited(_pendingReceiveCleanup.catchError((_) {}));
      final suppressErrors = shouldSuppressConnectionErrors?.call() ?? false;
      if (suppressErrors) {
        gracefulDisconnect = true;
      }

      if (!probeHandled && !suppressErrors) {
        sendConnectionError(tlsHandshakeFailureMessage());
      } else if (!connectionErrorSent &&
          !gracefulDisconnect &&
          !suppressErrors) {
        // 标记已上报，避免随后的 onDone 再报一次同样的会话结束。
        connectionErrorSent = true;
        toUiSendPort.send({
          'status': 'error',
          'fatal': 'true',
          'message': e.toString(),
        });
      }
      closeSocket();
    },
  );

  // 心跳：双方每 3 秒互发 ping，收到任意数据都算链路还在。只读的一方也能靠它
  // 发现对端掉网，不必等内核的 TCP 重传超时（默认十几分钟才报错）。
  Timer? heartbeatTimer;
  var lastHeartbeatTickAt = DateTime.now();
  heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
    if (socketClosed) {
      heartbeatTimer?.cancel();
      heartbeatTimer = null;
      return;
    }

    final now = DateTime.now();
    final sinceLastTick = now.difference(lastHeartbeatTickAt);
    lastHeartbeatTickAt = now;

    // 定时器严重迟到说明本机被系统挂起或长时间忙于同步工作，这段静默不能算掉线。
    if (sinceLastTick > const Duration(seconds: 10)) {
      lastInboundAt = now;
      return;
    }
    if (!probeHandled) {
      // 握手阶段由探测超时兜底，这里只刷新计时，避免把握手耗时当成掉线。
      lastInboundAt = now;
      return;
    }
    if (subscription.isPaused) {
      // 正在本地处理数据（例如写文件），对端这段时间收不到进度；刷新本地计时
      // 以免把自己算成掉线，同时照常发心跳让对端知道本机还在。
      lastInboundAt = now;
    } else if (now.difference(lastInboundAt) >= const Duration(seconds: 30)) {
      heartbeatTimer?.cancel();
      heartbeatTimer = null;
      // 明确标记是心跳判死，和 socket 报错、对端关闭连接区分开。
      debugPrint('[SESSION] heartbeat timeout');
      if (!(shouldSuppressConnectionErrors?.call() ?? false) &&
          !gracefulDisconnect) {
        sendConnectionError(
          'Connection lost. The other device disconnected unexpectedly.',
        );
      }
      closeSocket();
      return;
    }
    try {
      sendControlFrame({'type': 'ping'});
    } catch (_) {
      // 写入失败说明 socket 已不可用，收尾交给 onDone / onError。
    }
  });
}

Future<String> _resolveDownloadDirectory({String? commandDirectory}) async {
  if (commandDirectory != null && commandDirectory.isNotEmpty) {
    if (Platform.isAndroid && AndroidSafService.isTreeUri(commandDirectory)) {
      return commandDirectory;
    }
    final directory = Directory(commandDirectory);
    if (await directory.exists()) {
      return commandDirectory;
    }
  }

  if (Platform.isAndroid) {
    final dirObject = await getExternalStorageDirectory();
    if (dirObject != null) {
      return dirObject.path;
    }
  }

  final dirObject = await getDownloadsDirectory();
  if (dirObject != null) {
    return dirObject.path;
  }

  final fallback = await getApplicationDocumentsDirectory();
  return fallback.path;
}

String _resumeKeySegment(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return 'empty';
  }
  final safe = trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return safe.isEmpty ? 'empty' : safe;
}

String _partialPathFor(String directory, String resumeKey) {
  return '$directory/${_resumeKeySegment(resumeKey)}.flashbytepart';
}

Future<String> _partialDirectoryForResolved(String resolvedDirectory) async {
  if (Platform.isAndroid) {
    final support = await getApplicationSupportDirectory();
    return '${support.path}/flashbyte_partial';
  }
  return '$resolvedDirectory/.flashbyte_partial';
}

/// Reads the number of already-received bytes for [resumeKey].
///
/// The receiver writes into a regular partial file even when the final
/// destination is a SAF tree, so this lookup works for both platforms.
Future<int> _partialSizeFor({
  required String? configuredDownloadDirectory,
  required String resumeKey,
}) async {
  if (resumeKey.isEmpty) {
    return 0;
  }
  final resolved = await _resolveDownloadDirectory(
    commandDirectory: configuredDownloadDirectory,
  );
  final directory = await _partialDirectoryForResolved(resolved);
  final file = File(_partialPathFor(directory, resumeKey));
  try {
    if (await file.exists()) {
      return await file.length();
    }
  } catch (_) {}
  return 0;
}

/// Creates a resumable output target.
///
/// Data is always written to a regular partial file first. On success the
/// partial file is renamed (regular destination) or streamed into the SAF tree
/// and then deleted. That keeps append/resume independent of SAF capabilities.
Future<core.OutputTarget> _createOutputTarget({
  required String? configuredDownloadDirectory,
  required String originalFileName,
  required String resumeKey,
  required int startOffset,
  void Function(Object error)? onWriteError,
}) async {
  var resolvedDirectory = await _resolveDownloadDirectory(
    commandDirectory: configuredDownloadDirectory,
  );

  final usesSaf =
      Platform.isAndroid && AndroidSafService.isTreeUri(resolvedDirectory);
  if (!usesSaf && !await _directoryIsWritable(resolvedDirectory)) {
    // Sandboxed macOS denies the Downloads folder until the user grants
    // per-app consent (Privacy & Security > Files & Folders). Fall back to
    // the app container, which is always writable, instead of failing.
    final supportDir = await getApplicationSupportDirectory();
    final fallbackDirectory =
        '${supportDir.path}${Platform.pathSeparator}Downloads';
    await Directory(fallbackDirectory).create(recursive: true);
    debugPrint(
      '[RECEIVE] "$resolvedDirectory" is not writable; '
      'falling back to "$fallbackDirectory"',
    );
    resolvedDirectory = fallbackDirectory;
  }

  if (usesSaf) {
    final saf = Saf();
    final dirStat = await saf.stat(resolvedDirectory);
    if (dirStat == null) {
      throw Exception(
        'Download folder is no longer available. Select a new folder in Settings.',
      );
    }
  }

  final partialDirectory = await _partialDirectoryForResolved(
    resolvedDirectory,
  );
  await Directory(partialDirectory).create(recursive: true);
  final partialFile = File(_partialPathFor(partialDirectory, resumeKey));

  var existingSize = 0;
  try {
    if (await partialFile.exists()) {
      existingSize = await partialFile.length();
    }
  } catch (_) {}
  if (existingSize < startOffset) {
    throw Exception(
      'Partial file is shorter than the requested resume offset '
      '($existingSize < $startOffset).',
    );
  }
  if (existingSize > startOffset) {
    final handle = await partialFile.open(mode: FileMode.append);
    try {
      await handle.truncate(startOffset);
    } finally {
      await handle.close();
    }
  }

  final sink = partialFile.openWrite(mode: FileMode.append);
  if (onWriteError != null) {
    sink.done.then((_) {}, onError: onWriteError);
  }

  final finalName = usesSaf
      ? await _generateSafUniqueFileName(
          saf: Saf(),
          directoryUri: resolvedDirectory,
          originalFileName: originalFileName,
        )
      : core.generateUniqueFileName(resolvedDirectory, originalFileName);

  Future<void> finalize() async {
    if (usesSaf) {
      final saf = Saf();
      final entity = await saf.writeFileStream(
        resolvedDirectory,
        finalName,
        'application/octet-stream',
        partialFile.openRead(),
      );
      final stat = await saf.stat(entity.uri);
      final expected = await partialFile.length();
      if (stat == null || stat.length != expected) {
        try {
          await saf.delete(entity.uri);
        } catch (_) {}
        throw Exception('Could not save received file.');
      }
      await partialFile.delete();
      return;
    }

    final finalFile = File('$resolvedDirectory/$finalName');
    try {
      await partialFile.rename(finalFile.path);
    } catch (_) {
      // A cross-device rename is not possible on every platform; copy then
      // delete the partial instead.
      await partialFile.copy(finalFile.path);
      await partialFile.delete();
    }
  }

  return core.OutputTarget.custom(
    fileName: finalName,
    filePath: '$resolvedDirectory/$finalName',
    writeChunk: (data) => sink.add(data),
    closeWriter: () => sink.close(),
    finalizeFile: finalize,
    deleteFile: () async {
      await sink.close();
      try {
        if (await partialFile.exists()) {
          await partialFile.delete();
        }
      } catch (_) {}
    },
  );
}

/// Verifies [directory] accepts file creation by round-tripping a probe file.
Future<bool> _directoryIsWritable(String directory) async {
  final probe = File('$directory/.flashbyte_write_probe');
  try {
    final handle = await probe.open(mode: FileMode.write);
    await handle.close();
    try {
      await probe.delete();
    } catch (_) {}
    return true;
  } catch (_) {
    return false;
  }
}

Future<String> _generateSafUniqueFileName({
  required Saf saf,
  required String directoryUri,
  required String originalFileName,
}) async {
  final child = await saf.child(directoryUri, [originalFileName]);
  if (child == null) {
    return originalFileName;
  }

  final lastDotIndex = originalFileName.lastIndexOf('.');
  final name = lastDotIndex > 0
      ? originalFileName.substring(0, lastDotIndex)
      : originalFileName;
  final extension = lastDotIndex > 0
      ? originalFileName.substring(lastDotIndex)
      : '';

  int counter = 1;
  while (true) {
    final newFileName = '$name ($counter)$extension';
    final existing = await saf.child(directoryUri, [newFileName]);
    if (existing == null) {
      return newFileName;
    }
    counter++;
  }
}
