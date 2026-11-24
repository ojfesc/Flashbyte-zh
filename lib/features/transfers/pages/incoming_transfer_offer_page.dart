import 'dart:async';

import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flashbyte/models/discovered_device.dart';
import 'package:flashbyte/services/security/trusted_devices_service.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class IncomingTransferOfferPage extends StatefulWidget {
  const IncomingTransferOfferPage({
    super.key,
    required this.files,
    required this.sender,
    required this.receiverName,
    required this.receiverType,
    required this.receiverUsesTls,
    required this.onAccept,
    required this.onDecline,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, dynamic>? sender;
  final String receiverName;
  final DiscoveredDeviceType receiverType;
  final bool receiverUsesTls;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  State<IncomingTransferOfferPage> createState() =>
      _IncomingTransferOfferPageState();
}

class _IncomingTransferOfferPageState extends State<IncomingTransferOfferPage> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  _IncomingOfferOutcome? _outcome;
  bool _isClosing = false;
  bool _trustSender = false;

  Set<String> get _fileIds =>
      widget.files.map((file) => file['fileId']).whereType<String>().toSet();

  @override
  void initState() {
    super.initState();

    // 应用在后台时不渲染新帧，本页要等系统回到前台才构建。这段时间里
    // 用户在通知栏接受了请求，接受消息会先于本页订阅到达而丢失，
    // 所以先按 SocketService 记录的请求状态判断一次，已接受就不再批准。
    if (_fileIds.any(SocketService.instance.isIncomingOfferAccepted)) {
      _isClosing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
      return;
    }

    _subscription = SocketService.instance.messageStream.listen(
      _handleSocketMessage,
    );
  }

  void _handleSocketMessage(Map<String, dynamic> message) {
    if (!mounted || _isClosing || _outcome != null) return;

    final messageFileId = message['fileId'];
    final matchesFile =
        messageFileId is String && _fileIds.contains(messageFileId);

    switch (message['status']) {
      case 'start':
        // 接收侧开始写文件，说明请求已在别处被接受，本页不再需要批准。
        if (matchesFile && message['pendingAcceptance'] != true) {
          _closeAsAccepted();
        }
        break;
      case 'transfer_accepted':
      case 'progress':
      case 'completed':
        if (matchesFile) _closeAsAccepted();
        break;
      case 'transfer_cancelled':
        if (matchesFile) {
          _isClosing = true;
          Navigator.of(context).pop(false);
        }
        break;
      case 'offer_cancelled_by_sender':
        setState(() => _outcome = _IncomingOfferOutcome.senderCancelled);
        break;
      case 'error':
      case 'disconnect':
        setState(() => _outcome = _IncomingOfferOutcome.connectionEnded);
        break;
    }
  }

  /// 请求已由其他入口接受：关闭批准页并按“已接受”返回。
  void _closeAsAccepted() {
    if (_isClosing || _outcome != null) return;
    _isClosing = true;
    Navigator.of(context).pop(true);
  }

  void _accept() {
    if (_isClosing) return;
    _isClosing = true;
    final l10n = AppLocalizations.of(context);
    final fingerprint = widget.sender?['certFingerprint'] as String?;
    if (_trustSender && fingerprint != null && fingerprint.isNotEmpty) {
      final senderName = widget.sender?['name'] as String?;
