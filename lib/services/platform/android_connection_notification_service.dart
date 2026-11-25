import 'dart:async';
import 'dart:io';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/app/controllers/app_locale_controller.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/foundation.dart';

class AndroidConnectionNotificationService {
  AndroidConnectionNotificationService._();

  static final AndroidConnectionNotificationService instance =
      AndroidConnectionNotificationService._();

  static const int _foregroundServiceId = 8050;
  static const int _progressNotificationId = 8051;
  static const int _offerNotificationId = 8052;
  static const int _actionErrorNotificationId = 8053;

  static const String _connectionChannelKey = 'tcp_connection_service';
  static const String _progressChannelKey = 'file_transfer_progress';
  static const String _offerChannelKey = 'file_offers';
  static const Duration _progressUpdateInterval = Duration(milliseconds: 500);

  static const String _actionPause = 'progress_pause';
  static const String _actionResume = 'progress_resume';
  static const String _actionCancel = 'progress_cancel';
  static const String _actionSendFile = 'notif_send_file';
  static const String _actionDisconnect = 'notif_disconnect';
  static const String _actionAcceptFile = 'offer_accept';
  static const String _actionDeclineFile = 'offer_decline';
  static const String _actionCancelOffer = 'offer_cancel';

  final Map<String, _TransferProgress> _activeTransfers = {};
  final Set<String> _pausedTransfers = {};
  final Set<String> _pendingOffers = {};

  // 待批准批量请求的文件 id，按发送顺序保存；首个 id 是接受/拒绝的目标。
  final List<String> _pendingBatchIds = [];

  // 已接受、仍在传输的批量请求文件 id；取消时整批处理。
  final List<String> _activeBatchIds = [];

  // 进度通知聚焦的文件 id：批量传输时跟随正在传输的文件，而不是最后一个。
  String? _progressFocusFileId;

  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  Timer? _progressNotificationTimer;
  DateTime? _lastProgressNotificationUpdate;
  bool _initialized = false;

  /// 缓存的应用语言代码，用于通知文本本地化。
  String _languageCode = 'system';

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;

    _languageCode = await AppSettings.getLanguage();
    AppLocaleController.instance.addListener(_syncLanguage);

    _connectionSubscription = SocketService.instance.connectionStatusStream
        .listen(_handleConnectionChanged);
    _messageSubscription = SocketService.instance.messageStream.listen(
      _handleSocketMessage,
    );

    if (SocketService.instance.hasEstablishedConnection) {
      unawaited(_handleConnectionChanged(true));
    }
  }

  /// 将应用语言设置同步到通知文本缓存。
  void _syncLanguage() {
    final code = AppLocaleController.instance.languageCode;
    if (code != _languageCode) {
      _languageCode = code;
    }
  }

  /// 根据应用语言或系统语言返回中英文文本。
  String _t(String en, String zh) {
    final code = _languageCode;
    if (code == 'zh') return zh;
    if (code == 'en') return en;
    return Platform.localeName.toLowerCase().startsWith('zh') ? zh : en;
  }

  Future<void> handleNotificationAction(ReceivedAction receivedAction) async {
    final action = receivedAction.buttonKeyPressed;
    switch (action) {
      case _actionPause:
        _pauseActiveTransfer();
        break;
      case _actionResume:
        _resumeActiveTransfer();
        break;
      case _actionCancel:
        _cancelActiveTransfer();
        break;
      case _actionSendFile:
        await _pickAndSendFile();
        break;
      case _actionDisconnect:
        unawaited(SocketService.instance.disconnect());
        break;
      case _actionAcceptFile:
        _acceptPendingOffer();
        break;
      case _actionDeclineFile:
        _declinePendingOffer();
        break;
      case _actionCancelOffer:
        _cancelPendingOffer();
        break;
    }
  }

  Future<void> handleNotificationDismissed(
    ReceivedAction receivedAction,
  ) async {
    if (receivedAction.id == _foregroundServiceId &&
        SocketService.instance.hasEstablishedConnection) {
      unawaited(_showConnectionNotification());
    }
  }

  String? _activeTransferFileId() {
    final focus = _progressFocusFileId;
    if (focus != null && _activeTransfers.containsKey(focus)) {
      return focus;
    }
    if (_activeTransfers.isNotEmpty) return _activeTransfers.keys.last;
    final activeTransfers = SocketService.instance
        .getActiveTransferIsReceived();
    return activeTransfers.keys.isEmpty ? null : activeTransfers.keys.last;
  }

  /// 返回传输方向；无法确定时返回 null，宁可不动也不发错方向的控制帧。
  bool? _activeTransferIsReceived(String fileId) {
    final transfer = _activeTransfers[fileId];
    if (transfer != null) return transfer.isReceived;
    return SocketService.instance.getActiveTransferIsReceived()[fileId];
  }

  void _pauseActiveTransfer() {
    final fileId = _activeTransferFileId();
    if (fileId == null) return;
    final isReceiver = _activeTransferIsReceived(fileId);
    if (isReceiver == null) return;
    SocketService.instance.pauseTransfer(fileId, isReceiver: isReceiver);
  }

  void _resumeActiveTransfer() {
    final fileId = _activeTransferFileId();
    if (fileId == null) return;
    final isReceiver = _activeTransferIsReceived(fileId);
    if (isReceiver == null) return;
    SocketService.instance.resumeTransfer(fileId, isReceiver: isReceiver);
  }

  void _cancelActiveTransfer() {
    if (_activeBatchIds.isNotEmpty) {
      final batchIds = List<String>.of(_activeBatchIds);
      _activeBatchIds.clear();
      for (final fileId in batchIds) {
        SocketService.instance.cancelTransfer(fileId);
      }
      return;
    }

    final fileId = _activeTransferFileId();
    if (fileId == null) return;
    SocketService.instance.cancelTransfer(fileId);
  }

  Future<void> _pickAndSendFile() async {
    if (!SocketService.instance.hasEstablishedConnection) {
      _showActionError(_t('No device is connected.', '当前没有连接设备。'));
      return;
    }

    try {
      final pickedFile = await FastFilePicker.pickFile();
      if (pickedFile == null) return;
      final fileLocation = Platform.isAndroid && pickedFile.uri != null
          ? pickedFile.uri
          : pickedFile.path;
      if (fileLocation == null) {
        _showActionError(
          _t('Could not read the selected file.', '无法读取所选文件。'),
        );
        return;
      }
      SocketService.instance.sendFile(fileLocation);
    } catch (error, stackTrace) {
      _showActionError(
        _t('Could not open the file picker.', '无法打开文件选择器。'),
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flashbyte notifications',
          context: ErrorDescription('pick and send file'),
        ),
      );
    }
  }

  /// 通知栏操作失败时给出一条可见提示，避免点击后没有任何反馈。
  void _showActionError(String message) {
    unawaited(
      AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _actionErrorNotificationId,
          channelKey: _offerChannelKey,
          title: _t('Cannot send file', '无法发送文件'),
          body: message,
          category: NotificationCategory.Error,
          autoDismissible: true,
          showWhen: true,
          displayOnForeground: true,
          displayOnBackground: true,
        ),
      ),
    );
  }

  String get _peerName {
    final info = SocketService.instance.connectedPeerInfo;
    if (info == null) return _t('Unknown', '未知设备');
    final name = info['name'];
    return name is String ? name : _t('Unknown', '未知设备');
  }

  Future<void> _handleConnectionChanged(bool isConnected) async {
    if (isConnected) {
      // Shown when a transfer starts (after acceptance)
      return;
    }

    _activeTransfers.clear();
    _pausedTransfers.clear();
    _pendingOffers.clear();
    _pendingBatchIds.clear();
    _activeBatchIds.clear();
    _progressFocusFileId = null;
    _progressNotificationTimer?.cancel();
    _progressNotificationTimer = null;
    unawaited(AwesomeNotifications().cancel(_progressNotificationId));
    unawaited(AwesomeNotifications().cancel(_offerNotificationId));
    unawaited(AwesomeNotifications().cancel(_foregroundServiceId));
  }

  Future<void> _showConnectionNotification() async {
    if (!Platform.isAndroid) return;

    final hasTransfers = _activeTransfers.isNotEmpty;
    final actions = hasTransfers
        ? <NotificationActionButton>[]
        : [
            NotificationActionButton(
              key: _actionSendFile,
              label: _t('Send file', '发送文件'),
              actionType: ActionType.Default,
              autoDismissible: false,
            ),
            NotificationActionButton(
              key: _actionDisconnect,
              label: _t('Disconnect', '断开连接'),
              actionType: ActionType.SilentAction,
              autoDismissible: false,
            ),
          ];

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _foregroundServiceId,
          channelKey: _connectionChannelKey,
          title: 'Flashbyte',
          body: _t('Connected to $_peerName', '已连接到 $_peerName'),
          category: NotificationCategory.Service,
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
          wakeUpScreen: false,
        ),
        actionButtons: actions.isEmpty ? null : actions,
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flashbyte notifications',
          context: ErrorDescription('show connection notification'),
        ),
      );
    }
  }

  void _handleSocketMessage(Map<String, dynamic> message) {
    final status = message['status'] ?? message['command'];

    switch (status) {
      case 'peer_info':
        // Shown when a transfer starts (after acceptance)
        break;
      case 'send_start':
        if (message['pendingAcceptance'] == true) {
          _showSenderPendingNotification(message);
          _startTransfer(message, isReceived: false);
        } else {
          _startTransfer(message, isReceived: false);
        }
        break;
      case 'start':
        if (message['pendingAcceptance'] == true) {
          if (message['isBatch'] == true) {
            _showReceiverBatchNotification(message);
          } else {
            _showReceiverOfferNotification(message);
          }
        } else {
          _startTransfer(message, isReceived: true);
        }
        break;
      case 'send_progress':
      case 'progress':
        {
          _updateTransfer(message);
          final fileId = message['fileId'] as String?;
          if (fileId != null && _pendingOffers.contains(fileId)) {
            _handleOfferResolved(message);
            if (_activeTransfers.containsKey(fileId)) {
              unawaited(_showConnectionNotification());
              _scheduleProgressNotificationUpdate(force: true);
            }
          }
          break;
        }
      case 'transfer_paused':
        _markTransferPaused(message);
        break;
      case 'transfer_resumed':
        _markTransferResumed(message);
        break;
      case 'transfer_accepted':
        {
          final fileId = message['fileId'] as String?;
          _resolveOffer(message);
          if (fileId != null && _activeTransfers.containsKey(fileId)) {
            unawaited(_showConnectionNotification());
            _scheduleProgressNotificationUpdate(force: true);
          }
          break;
        }
      case 'transfer_declined':
        _resolveOffer(message);
        _completeTransfer(message);
        break;
      case 'transfer_cancelled':
        _resolveOffer(message);
        _completeTransfer(message);
        break;
      case 'send_complete':
      case 'completed':
      case 'error':
      case 'disconnect':
        _completeTransfer(message);
        if (status == 'disconnect' || status == 'error') {
          unawaited(AwesomeNotifications().cancel(_foregroundServiceId));
        }
        break;
      case 'outgoing_offer_cancelled':
      case 'offer_cancelled_by_sender':
        _handleOfferCancelledBySender();
        break;
    }
  }

  void _startTransfer(
    Map<String, dynamic> message, {
    required bool isReceived,
  }) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) return;

    _activeTransfers[fileId] = _TransferProgress(
      fileId: fileId,
      isReceived: isReceived,
      direction: isReceived ? 'receiving' : 'sending',
      fileName: message['fileName'] as String? ?? 'file',
      progress: 0,
    );

    if (_pendingOffers.contains(fileId)) return;

    _progressFocusFileId = fileId;
    unawaited(_showConnectionNotification());
    _scheduleProgressNotificationUpdate(force: true);
  }

  void _updateTransfer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final progress = (message['progress'] as num?)?.toDouble();
    if (fileId == null || progress == null) return;

    final transfer = _activeTransfers[fileId];
    if (transfer == null) return;

    _progressFocusFileId = fileId;
    final nextPercent = (progress.clamp(0.0, 1.0) * 100).floor();
    if (nextPercent == transfer.lastShownPercent) return;

    transfer
      ..progress = progress.clamp(0.0, 1.0)
      ..lastShownPercent = nextPercent;

    if (nextPercent >= 100) return;

    _scheduleProgressNotificationUpdate();
  }

  void _markTransferPaused(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) return;
    _pausedTransfers.add(fileId);
    _scheduleProgressNotificationUpdate();
  }

  void _markTransferResumed(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) return;
    _pausedTransfers.remove(fileId);
    _scheduleProgressNotificationUpdate();
  }

  void _completeTransfer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId == null) {
      _activeTransfers.clear();
      _pausedTransfers.clear();
      _progressFocusFileId = null;
    } else {
      _activeTransfers.remove(fileId);
      _pausedTransfers.remove(fileId);
      if (_progressFocusFileId == fileId) {
        _progressFocusFileId = null;
      }
    }

    if (_activeTransfers.isEmpty) {
      _activeBatchIds.clear();
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(AwesomeNotifications().cancel(_progressNotificationId));
      unawaited(_showConnectionNotification());
    }

    if (_activeTransfers.isNotEmpty) {
      _scheduleProgressNotificationUpdate();
    }
  }

  void _showSenderPendingNotification(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final fileName = message['fileName'] as String? ?? 'file';
    if (fileId == null) return;

    _pendingOffers.add(fileId);
    if (message['isBatch'] == true && !_pendingBatchIds.contains(fileId)) {
      _pendingBatchIds.add(fileId);
    }
    final body = _pendingBatchIds.length > 1
        ? _t(
            '${_pendingBatchIds.length} files',
            '${_pendingBatchIds.length} 个文件',
          )
        : fileName;

    unawaited(
      AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _offerNotificationId,
          channelKey: _offerChannelKey,
          title: _t('Waiting for receiver to accept', '等待接收方接受'),
          body: body,
          locked: true,
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
        ),
        actionButtons: [
          NotificationActionButton(
            key: _actionCancelOffer,
            label: _t('Cancel', '取消'),
            actionType: ActionType.SilentAction,
            autoDismissible: false,
          ),
        ],
      ),
    );
  }

  void _showReceiverOfferNotification(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    final fileName = message['fileName'] as String? ?? 'file';
    if (fileId == null) return;

    _pendingOffers.add(fileId);

    unawaited(
      AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _offerNotificationId,
          channelKey: _offerChannelKey,
          title: _t('Incoming file', '接收文件'),
          body: fileName,
          locked: true,
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
        ),
        actionButtons: [
          NotificationActionButton(
            key: _actionAcceptFile,
            label: _t('Accept', '接受'),
            actionType: ActionType.SilentAction,
            autoDismissible: false,
          ),
          NotificationActionButton(
            key: _actionDeclineFile,
            label: _t('Decline', '拒绝'),
            actionType: ActionType.SilentAction,
            autoDismissible: false,
          ),
        ],
      ),
    );
  }

  /// 批量接收通知：file_batch 的 start 没有顶层 fileId，按文件列表展示。
  void _showReceiverBatchNotification(Map<String, dynamic> message) {
    final rawFiles = message['files'] as List<dynamic>?;
    if (rawFiles == null || rawFiles.isEmpty) return;

    final fileIds = <String>[];
    for (final file in rawFiles) {
      if (file is Map && file['fileId'] is String) {
        fileIds.add(file['fileId'] as String);
      }
    }
    if (fileIds.isEmpty) return;

    _pendingOffers.addAll(fileIds);
    _pendingBatchIds
      ..clear()
      ..addAll(fileIds);

    unawaited(
      AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _offerNotificationId,
          channelKey: _offerChannelKey,
          title: _t('Incoming files', '接收多个文件'),
          body: _t('${fileIds.length} files', '${fileIds.length} 个文件'),
          locked: true,
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
        ),
        actionButtons: [
          NotificationActionButton(
            key: _actionAcceptFile,
            label: _t('Accept', '接受'),
            actionType: ActionType.SilentAction,
            autoDismissible: false,
          ),
          NotificationActionButton(
            key: _actionDeclineFile,
            label: _t('Decline', '拒绝'),
            actionType: ActionType.SilentAction,
            autoDismissible: false,
          ),
        ],
      ),
    );
  }

  void _handleOfferResolved(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId != null) {
      _pendingOffers.remove(fileId);
    }
    if (_pendingOffers.isEmpty) {
      unawaited(AwesomeNotifications().cancel(_offerNotificationId));
    }
  }

  /// 请求被接受/拒绝/取消时同步通知状态；批量请求的首个文件结束时清整组。
  void _resolveOffer(Map<String, dynamic> message) {
    final fileId = message['fileId'] as String?;
    if (fileId != null &&
        _pendingBatchIds.isNotEmpty &&
        fileId == _pendingBatchIds.first) {
      if (message['status'] == 'transfer_accepted') {
        _activeBatchIds
          ..clear()
          ..addAll(_pendingBatchIds);
      }
      _clearPendingOfferGroup();
      return;
    }
    _handleOfferResolved(message);
  }

  /// 批量请求只显示一条通知，处理后把整组从待批准集合移除并收起通知。
  void _clearPendingOfferGroup() {
    if (_pendingBatchIds.isNotEmpty) {
      for (final fileId in _pendingBatchIds) {
        _pendingOffers.remove(fileId);
      }
      _pendingBatchIds.clear();
    }
    if (_pendingOffers.isEmpty) {
      unawaited(AwesomeNotifications().cancel(_offerNotificationId));
    }
  }

  /// 接受/拒绝的目标：批量请求取首个文件，普通请求取最早的一条。
  String? _nextPendingOfferId() {
    if (_pendingBatchIds.isNotEmpty) return _pendingBatchIds.first;
    if (_pendingOffers.isEmpty) return null;
    return _pendingOffers.first;
  }

  void _handleOfferCancelledBySender() {
    _pendingOffers.clear();
    _pendingBatchIds.clear();
    unawaited(AwesomeNotifications().cancel(_offerNotificationId));
  }

  void _acceptPendingOffer() {
    final fileId = _nextPendingOfferId();
    if (fileId == null) return;
    SocketService.instance.acceptTransfer(fileId);
    if (_pendingBatchIds.isNotEmpty) {
      _activeBatchIds
        ..clear()
        ..addAll(_pendingBatchIds);
    }
    _clearPendingOfferGroup();
  }

  void _declinePendingOffer() {
    final fileId = _nextPendingOfferId();
    if (fileId == null) return;
    SocketService.instance.declineTransfer(fileId);
    _clearPendingOfferGroup();
  }

  void _cancelPendingOffer() {
    if (_pendingOffers.isEmpty) return;

    // 取消要落到发送队列：只结束请求协商时，发送方仍会停在等待同意的循环里，
    // 接收方之后接受仍会开始传输。逐个文件取消传输后，隔离区会标记已取消、
    // 通知接收方，并把 transfer_cancelled 推给界面。
    for (final fileId in List<String>.of(_pendingOffers)) {
      SocketService.instance.cancelTransfer(fileId);
    }
    _pendingBatchIds.clear();

    // 同时结束本次请求协商，让审批页等界面按“已取消”关闭。
    unawaited(SocketService.instance.cancelOutgoingOffer());
  }

  /// 进度通知要展示/操作的传输：优先跟随正在传输的文件，取不到时退回最后登记的一个。
  _TransferProgress? _progressTransfer() {
    final focus = _progressFocusFileId;
    if (focus != null) {
      final transfer = _activeTransfers[focus];
      if (transfer != null) return transfer;
    }
    return _activeTransfers.isEmpty ? null : _activeTransfers.values.last;
  }

  void _scheduleProgressNotificationUpdate({bool force = false}) {
    final transfer = _progressTransfer();
    if (transfer == null) return;

    final percent = (transfer.progress.clamp(0.0, 1.0) * 100).floor();
    if (percent >= 100) return;

    if (force || _lastProgressNotificationUpdate == null) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(_showProgressNotification());
      return;
    }

    final elapsed = DateTime.now().difference(_lastProgressNotificationUpdate!);
    if (elapsed >= _progressUpdateInterval) {
      _progressNotificationTimer?.cancel();
      _progressNotificationTimer = null;
      unawaited(_showProgressNotification());
      return;
    }

    _progressNotificationTimer ??= Timer(
      _progressUpdateInterval - elapsed,
      () {
        _progressNotificationTimer = null;
        unawaited(_showProgressNotification());
      },
    );
  }

  Future<void> _showProgressNotification() async {
    final transfer = _progressTransfer();
    if (transfer == null) return;

    final percent = (transfer.progress.clamp(0.0, 1.0) * 100).floor();
    if (percent >= 100) return;

    _lastProgressNotificationUpdate = DateTime.now();

    final isPaused = _pausedTransfers.contains(transfer.fileId);
    final directionLabel = transfer.direction == 'receiving'
        ? _t('Receiving', '接收中')
        : _t('Sending', '发送中');
    final actions = [
      if (isPaused)
        NotificationActionButton(
          key: _actionResume,
          label: _t('Resume', '继续'),
          actionType: ActionType.SilentAction,
          autoDismissible: false,
        )
      else
        NotificationActionButton(
          key: _actionPause,
          label: _t('Pause', '暂停'),
          actionType: ActionType.SilentAction,
          autoDismissible: false,
        ),
      NotificationActionButton(
        key: _actionCancel,
        label: _t('Cancel', '取消'),
        actionType: ActionType.SilentAction,
        autoDismissible: false,
      ),
    ];

    try {
      await AwesomeNotifications().createNotification(
        content: NotificationContent(
          id: _progressNotificationId,
          channelKey: _progressChannelKey,
          title: '$directionLabel ${transfer.fileName}',
          body: _t('$percent% complete', '$percent% 完成'),
          notificationLayout: NotificationLayout.ProgressBar,
          locked: true,
          progress: percent.toDouble(),
          autoDismissible: false,
          showWhen: false,
          displayOnForeground: true,
          displayOnBackground: true,
          category: NotificationCategory.Progress,
        ),
        actionButtons: actions,
      );
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'flashbyte notifications',
          context: ErrorDescription('show progress notification'),
        ),
      );
    }
  }

  Future<void> dispose() async {
    _progressNotificationTimer?.cancel();
    AppLocaleController.instance.removeListener(_syncLanguage);
    await _connectionSubscription?.cancel();
    await _messageSubscription?.cancel();
    await AwesomeNotifications().cancel(_foregroundServiceId);
  }
}

class _TransferProgress {
  _TransferProgress({
    required this.fileId,
    required this.isReceived,
    required this.direction,
    required this.fileName,
    required this.progress,
  });

  final String fileId;
  final bool isReceived;

  /// 语言无关的方向标识：`receiving` 或 `sending`。
  final String direction;
  final String fileName;
  double progress;
  int lastShownPercent = -1;
}
