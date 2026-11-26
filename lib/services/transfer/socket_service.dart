import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/services/security/tls_identity_service.dart';
import 'package:flashbyte/services/security/trusted_devices_service.dart';
import 'package:flashbyte/services/transfer/file_transfer_isolate.dart';

typedef IsolateMessage = Map<String, dynamic>;

class SocketStartupCancelled implements Exception {
  const SocketStartupCancelled();

  @override
  String toString() => 'Socket startup was cancelled.';
}

class SocketService {
  SocketService._privateConstructor();
  static final SocketService instance = SocketService._privateConstructor();

  Isolate? _receiverIsolate;
  SendPort? _toIsolateSendPort;

  ReceivePort? _uiReceivePort = ReceivePort();
  StreamSubscription? _streamSubscription;
  bool _disconnectRequested = false;
  int _connectionGeneration = 0;
  Completer<void>? _disconnectCompleter;
  Completer<void>? _outgoingOfferCancelCompleter;
  Future<void> _lifecycleOperation = Future.value();

  final _messageStreamController = StreamController<IsolateMessage>.broadcast();
  final _connectionStatusController = StreamController<bool>.broadcast();
  final Map<String, IsolateMessage> _transferStartMessages = {};
  final Map<String, IsolateMessage> _transferLatestMessages = {};
  IsolateMessage? _connectedPeerInfo;
  Stream<IsolateMessage> get messageStream => _messageStreamController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  bool get isRunning => _receiverIsolate != null;
  bool get isHosting => _hostIsListening;
  bool get isSecureHosting => _hostIsListening && _hostUsesTls;
  bool get hasEstablishedConnection => _hasEstablishedConnection;
  /// Whether the current isolate is a client session (this device is sending).
  ///
  /// The file-selection page uses this to avoid starting a receive host while
  /// a sender session is being reconnected.
  bool get isClientMode => _isClientMode;
  IsolateMessage? get connectedPeerInfo => _connectedPeerInfo == null
      ? null
      : Map<String, dynamic>.from(_connectedPeerInfo!);

  bool _hasEstablishedConnection = false;
  bool _hostIsListening = false;
  bool _hostUsesTls = false;
  bool _isClientMode = false;

  Future<void> startHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
  }) async {
    await _runLifecycleOperation(
      () => _startIsolate(
        mode: 'host',
        host: host,
        port: port,
        useTLS: useTLS,
      ),
    );
  }

  Future<void> connectToHost(
    String host, {
    int port = 8050,
    bool useTLS = false,
    String? trustedCertificatePem,
    String? expectedCertificateFingerprint,
    String? trustedPeerId,
  }) async {
    await _runLifecycleOperation(
      () => _startIsolate(
        mode: 'client',
        host: host,
        port: port,
        useTLS: useTLS,
        trustedCertificatePem: trustedCertificatePem,
        expectedCertificateFingerprint: expectedCertificateFingerprint,
        trustedPeerId: trustedPeerId,
      ),
    );
  }

  Future<T> _runLifecycleOperation<T>(Future<T> Function() operation) async {
    final previousOperation = _lifecycleOperation;
    final operationCompleter = Completer<void>();
    _lifecycleOperation = operationCompleter.future;

    try {
      try {
        await previousOperation;
      } catch (_) {
        // A failed previous startup should not poison the next lifecycle action.
      }

      return await operation();
    } finally {
      if (!operationCompleter.isCompleted) {
        operationCompleter.complete();
      }
    }
  }

  Future<void> _startIsolate({
    required String mode,
    String? host,
    required int port,
    bool useTLS = false,
    String? trustedCertificatePem,
    String? expectedCertificateFingerprint,
    String? trustedPeerId,
  }) async {
    if (mode == 'client') {
      // A reconnect must not send the graceful "transfer_cancelled"
      // disconnect: the receiver would discard the partial file that this
      // reconnect is about to resume. Closing the socket is enough; the
      // receiver's onDone path keeps the partial.
      stopConnection();
    } else {
      await _stopConnectionGracefully();
    }
    final generation = _connectionGeneration;
    _isClientMode = mode == 'client';
    _hostUsesTls = mode == 'host' && useTLS;
    _disconnectRequested = false;
    _transferStartMessages.clear();
    _transferLatestMessages.clear();
    _connectedPeerInfo = null;
    _setConnectionEstablished(false);

    String? certPath;
    String? keyPath;
    String? certificateFingerprint;
    String? trustedCertPath;
    final downloadDirectory = await AppSettings.getDownloadDirectory();
    final deviceName = await AppSettings.getDeviceName();

    // Always load the device identity so peer_info carries this device's
    // certificate fingerprint — it's the stable identifier used by the
    // trusted devices list, independent of whether TLS is enabled.
    {
      final identity = await TlsIdentityService.getOrCreateIdentity();
      certificateFingerprint = identity.fingerprint;
      if (useTLS) {
        certPath = identity.certificatePath;
        keyPath = identity.privateKeyPath;

        if (mode == 'client') {
          if (expectedCertificateFingerprint == null ||
              expectedCertificateFingerprint.trim().isEmpty) {
            throw Exception(
              'TLS requires a discovered receiver certificate. Select the receiver from discovery and try again.',
            );
          }

          if (trustedCertificatePem != null &&
              trustedCertificatePem.trim().isNotEmpty) {
            trustedCertPath =
                await TlsIdentityService.writeTrustedPeerCertificate(
                  peerId: trustedPeerId ?? host ?? 'peer',
                  certificatePem: trustedCertificatePem,
                );
          }
        }
      }
    }

    final completer = Completer<SendPort>();
    final hostingCompleter = Completer<void>();

    final uiReceivePort = ReceivePort();
    _uiReceivePort = uiReceivePort;
    final RootIsolateToken? rootToken = RootIsolateToken.instance;

    if (rootToken == null) {
      throw Exception('Fatal: RootIsolateToken is null!');
    }

    _streamSubscription = uiReceivePort.listen(
      (message) async {
        if (message is SendPort) {
          if (!completer.isCompleted) {
            completer.complete(message);
          }
          return;
        }
        if (generation != _connectionGeneration) {
          return;
        }

        final typedMessage = message as IsolateMessage;
        final status = typedMessage['status'] ?? typedMessage['command'];
        if (status == 'hosting' && !hostingCompleter.isCompleted) {
          _hostIsListening = true;
          hostingCompleter.complete();
        } else if (mode == 'host' &&
            status == 'error' &&
            !hostingCompleter.isCompleted) {
          hostingCompleter.completeError(
            Exception(typedMessage['message'] ?? 'Failed to start server'),
          );
        }
        if (status == 'client_connected' || status == 'connected_to_host') {
          _disconnectRequested = false;
          _setConnectionEstablished(true);
        } else if (status == 'disconnect' ||
            (status == 'error' && typedMessage['fatal'] == 'true')) {
          // 只有致命错误代表连接结束；普通操作错误不影响会话状态。
          _setConnectionEstablished(false);
          if (status == 'disconnect') {
            _completeDisconnectWaiter();
          }
        }
        if (status == 'outgoing_offer_cancelled') {
          final completer = _outgoingOfferCancelCompleter;
          if (completer != null && !completer.isCompleted) {
            completer.complete();
          }
          _outgoingOfferCancelCompleter = null;
        }
        if (status == 'error' && _disconnectRequested) {
          return;
        }
        _publishMessage(typedMessage);
        if (status == 'disconnect') {
          Future.microtask(() => _stopConnectionIfCurrent(generation));
        }
      },
    );

    final receiverIsolate = await Isolate.spawn(
      fileReceiverIsolate,
      [
        uiReceivePort.sendPort,
        rootToken,
      ],
    );
    if (generation != _connectionGeneration) {
      receiverIsolate.kill(priority: Isolate.immediate);
      throw const SocketStartupCancelled();
    }
    _receiverIsolate = receiverIsolate;

    _toIsolateSendPort = await completer.future;
    if (generation != _connectionGeneration) {
      throw const SocketStartupCancelled();
    }

    _toIsolateSendPort!.send({
      'command': 'connect',
      'mode': mode,
      'host': host,
      'port': port,
      'useTLS': useTLS,
      'certPath': certPath,
      'keyPath': keyPath,
      'certificateFingerprint': certificateFingerprint,
      'trustedCertPath': trustedCertPath,
      'expectedCertificateFingerprint': expectedCertificateFingerprint,
      'downloadDirectory': downloadDirectory,
      'deviceName': deviceName,
      'deviceType': Platform.isAndroid || Platform.isIOS ? 'phone' : 'laptop',
      'listeningPort': port,
    });

    if (mode == 'host') {
      await hostingCompleter.future.timeout(const Duration(seconds: 10));
    }
  }

  /// 发送单个文件。[clipboard] 为 true 时接收端不落盘，而是把内容写进粘贴板。
  /// [displayName] 覆盖传输中显示的文件名，粘贴板文本用它显示可读名称。
  void sendFile(
    String filePath, {
    String? displayName,
    bool clipboard = false,
  }) {
    if (_toIsolateSendPort == null) {
      return;
    }

    _toIsolateSendPort!.send({
      'command': 'send_file',
      'filePath': filePath,
      if (displayName != null) 'displayName': displayName,
      'clipboard': clipboard,
    });
  }

  /// 通知已连接的对端本机改名，避免对方等到重连才看到新名称。
  void updateDeviceName(String deviceName) {
    _toIsolateSendPort?.send({
      'command': 'update_peer_info',
      'deviceName': deviceName,
    });
  }

  void sendFiles(List<String> filePaths) {
    if (_toIsolateSendPort == null || filePaths.isEmpty) {
      return;
    }

    _toIsolateSendPort!.send({
      'command': 'send_files',
      'filePaths': filePaths,
    });
  }

  /// 逐个发送多个文件：每个文件都是独立的单文件请求，不会合并成批量请求。
  void sendFilesSeparately(List<String> filePaths) {
    final sendPort = _toIsolateSendPort;
    if (sendPort == null || filePaths.isEmpty) {
      return;
    }
    sendPort.send({
      'command': 'send_files_separately',
      'filePaths': filePaths,
    });
  }

  /// 丢弃还没开始发送的排队文件；正在传的文件用 [cancelTransfer] 结束。
  void cancelQueuedSends() {
    _toIsolateSendPort?.send({'command': 'cancel_queued_sends'});
  }

  void pauseTransfer(String fileId, {required bool isReceiver}) {
    _sendTransferControl(
      'pause_transfer',
      fileId,
      role: isReceiver ? 'receiver' : 'sender',
    );
  }

  void resumeTransfer(String fileId, {required bool isReceiver}) {
    _sendTransferControl(
      'resume_transfer',
      fileId,
      role: isReceiver ? 'receiver' : 'sender',
    );
  }

  void cancelTransfer(String fileId) {
    _sendTransferControl('cancel_transfer', fileId);
  }

  void acceptTransfer(String fileId) {
    _sendTransferControl('accept_transfer', fileId);
  }

  void declineTransfer(String fileId) {
    _sendTransferControl('decline_transfer', fileId);
  }

  void setDownloadDirectory(String? directory) {
    final sendPort = _toIsolateSendPort;
    if (sendPort == null) return;
    sendPort.send({
      'command': 'set_download_directory',
      'downloadDirectory': directory,
    });
  }

  Future<void> cancelOutgoingOffer() async {
    final sendPort = _toIsolateSendPort;
    if (sendPort == null) return;
    final completer = _outgoingOfferCancelCompleter ??= Completer<void>();
    sendPort.send({'command': 'cancel_outgoing_offer'});
    try {
      await completer.future.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // The following graceful disconnect still cleans up a closed socket.
    } finally {
      if (identical(_outgoingOfferCancelCompleter, completer)) {
        _outgoingOfferCancelCompleter = null;
      }
    }
  }

  void _sendTransferControl(String command, String fileId, {String? role}) {
    _toIsolateSendPort?.send({
      'command': command,
      'fileId': fileId,
      'role': role,
    });
  }

  void replayTransferState() {
    for (final entry in _transferStartMessages.entries) {
      _messageStreamController.add(Map<String, dynamic>.from(entry.value));
      final latestMessage = _transferLatestMessages[entry.key];
      if (latestMessage != null) {
        _messageStreamController.add(
          Map<String, dynamic>.from(latestMessage),
        );
      }
    }
  }

  Future<void> disconnect() {
    final sendPort = _toIsolateSendPort;
    if (_uiReceivePort == null || sendPort == null) {
      stopConnection();
      return Future.value();
    }
    _disconnectRequested = true;
    _setConnectionEstablished(false);
    final completer = _disconnectCompleter ??= Completer<void>();
    try {
      sendPort.send({
        'command': 'disconnect',
      });
    } catch (_) {
      stopConnection();
      return Future.value();
    }
    // 隔离进程可能已经不再回执（例如 socket 已死）；超时后强制拆除，调用方不会挂起。
    return completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        stopConnection();
      },
    );
  }

  Future<void> stopConnectionGracefully({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    await _runLifecycleOperation(
      () => _stopConnectionGracefully(timeout: timeout),
    );
  }

  Future<void> _stopConnectionGracefully({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_receiverIsolate == null && _toIsolateSendPort == null) {
      stopConnection();
      return;
    }

    try {
      await disconnect().timeout(timeout);
      stopConnection();
    } on TimeoutException {
      stopConnection();
    }
  }

  void stopConnection() {
    _connectionGeneration++;
    _setConnectionEstablished(false);
    _completeDisconnectWaiter();
    _streamSubscription?.cancel();
    _uiReceivePort?.close();
    _receiverIsolate?.kill(priority: Isolate.immediate);

    _receiverIsolate = null;
    _toIsolateSendPort = null;
    _streamSubscription = null;
    _uiReceivePort = null;
    _hostIsListening = false;
    _hostUsesTls = false;
    _isClientMode = false;
    _disconnectRequested = false;
  }

  void _completeDisconnectWaiter() {
    final completer = _disconnectCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _disconnectCompleter = null;
    final offerCompleter = _outgoingOfferCancelCompleter;
    if (offerCompleter != null && !offerCompleter.isCompleted) {
      offerCompleter.complete();
    }
    _outgoingOfferCancelCompleter = null;
  }

  void _stopConnectionIfCurrent(int generation) {
    if (generation == _connectionGeneration) {
      stopConnection();
    }
  }

  void _setConnectionEstablished(bool value) {
    if (_hasEstablishedConnection == value) {
      return;
    }

    _hasEstablishedConnection = value;
    _connectionStatusController.add(value);
  }

  Map<String, bool> getActiveTransferIsReceived() {
    final result = <String, bool>{};
    for (final entry in _transferStartMessages.entries) {
      final status = entry.value['status'] as String?;
      if (status == 'start') {
        result[entry.key] = true;
      } else if (status == 'send_start') {
        result[entry.key] = false;
      }
    }
    return result;
  }

  /// 判断传入的文件请求是否已经被接受。
  ///
  /// 接受请求不一定经过批准页：用户可以在通知栏直接点“接受”。应用在后台
  /// 时不渲染新帧，批准页要等回到前台才构建，期间收到的接受消息它收不到，
  /// 所以批准页打开前必须按这里记录的请求状态判断是否还需要提示批准。
  bool isIncomingOfferAccepted(String fileId) {
    final startMessage = _transferStartMessages[fileId];
    if (startMessage == null) return false;

    // 接收侧开始写文件前会再发一条不带 pendingAcceptance 的 start 消息。
    if (startMessage['status'] == 'start' &&
        startMessage['pendingAcceptance'] != true) {
      return true;
    }

    final latestStatus = _transferLatestMessages[fileId]?['status'];
    return latestStatus == 'transfer_accepted' ||
        latestStatus == 'progress' ||
        latestStatus == 'completed';
  }

  /// 判断传入的文件请求是否已经被拒绝或取消。
  ///
  /// 与“已接受”同理：用户可能在通知栏直接拒绝请求，或发送方在另一端取消，
  /// 而批准页要等应用回到前台才构建，期间的消息它收不到。批准页打开前先按
  /// 这里记录的最新状态判断请求是否已经结束，已结束就不再显示批准界面。
  bool isIncomingOfferResolved(String fileId) {
    final startMessage = _transferStartMessages[fileId];
    if (startMessage == null) return false;

    final latestStatus = _transferLatestMessages[fileId]?['status'];
    return latestStatus == 'transfer_cancelled' ||
        latestStatus == 'transfer_declined';
  }

  /// 发送方取消请求时，把仍处于待批准状态的传入请求标记为已取消。
  ///
  /// 取消帧本身不带文件 id；批准页可能还没构建、收不到后续消息，所以这里
  /// 把记录里的待批准请求补上结束状态，让批准页打开时能直接关闭。
  void _markPendingIncomingOffersCancelled() {
    for (final entry in _transferStartMessages.entries) {
      final startMessage = entry.value;
      final isPendingIncoming =
          startMessage['status'] == 'start' &&
          startMessage['pendingAcceptance'] == true;
      if (!isPendingIncoming) continue;
      if (_transferLatestMessages.containsKey(entry.key)) continue;
      _transferLatestMessages[entry.key] = {
        'status': 'transfer_cancelled',
        'fileId': entry.key,
      };
    }
  }

  /// 记录一次文件请求的开始状态，供批准页在构建时查询请求是否已被处理。
  ///
  /// 批量请求的 start 没有顶层 fileId，文件 id 在 files 列表里；按列表里的每个
  /// id 分别记录，批量请求才能和单个文件一样按 id 查到请求状态。
  void _recordOfferStart(IsolateMessage message, {required String? fileId}) {
    final startMessage = Map<String, dynamic>.from(message);
    final fileIds = <String>{};

    if (fileId != null) {
      fileIds.add(fileId);
    } else {
      final files = message['files'];
      if (files is List) {
        for (final file in files) {
          if (file is Map && file['fileId'] is String) {
            fileIds.add(file['fileId'] as String);
          }
        }
      }
    }

    for (final id in fileIds) {
      _transferStartMessages[id] = startMessage;
      _transferLatestMessages.remove(id);
    }
  }

  void _publishMessage(IsolateMessage message) {
    final status = message['status'] ?? message['command'];
    if (status == 'offer_cancelled_by_sender') {
      _markPendingIncomingOffersCancelled();
    }
    if (status == 'peer_info') {
      _connectedPeerInfo = Map<String, dynamic>.from(message);
      unawaited(
        TrustedDevicesService.instance.updateNameIfTrusted(
          message['certFingerprint'] as String?,
          message['name'] as String?,
        ),
      );
    }
    final fileId = message['fileId'] as String?;
    if (status == 'start' || status == 'send_start') {
      _recordOfferStart(message, fileId: fileId);
    } else if (fileId != null &&
        (status == 'progress' ||
            status == 'send_progress' ||
            status == 'completed' ||
            status == 'send_complete' ||
            status == 'transfer_paused' ||
            status == 'transfer_resumed' ||
            status == 'transfer_pending' ||
            status == 'transfer_accepted' ||
            status == 'transfer_declined' ||
            status == 'transfer_cancelled')) {
      _transferLatestMessages[fileId] = Map<String, dynamic>.from(message);
    }

    _messageStreamController.add(message);
  }
}
