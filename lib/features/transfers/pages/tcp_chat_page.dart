import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flashbyte/services/security/trusted_devices_service.dart';
import 'package:flashbyte/services/sharing/incoming_share_service.dart';
import 'package:flashbyte/services/platform/android_document_service.dart';
import 'package:flashbyte/services/platform/android_saf_service.dart';
import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flashbyte/services/transfer/clipboard_text_file.dart';
import 'package:flashbyte/features/transfers/widgets/transfer_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

/// 会话异常结束的两种结果；底部发送入口按它选择显示的文案和图标。
enum _SessionIssue { connectionLost, transferInterrupted }

class TcpChatPage extends StatefulWidget {
  final List<FastFilePickerPath> initialFiles;
  final List<Map<String, dynamic>>? initialBatchFiles;

  const TcpChatPage({
    super.key,
    this.initialFiles = const [],
    this.initialBatchFiles,
  });

  @override
  State<TcpChatPage> createState() => _TcpChatPageState();
}

class _TcpChatPageState extends State<TcpChatPage> {
  static const double _wideLayoutBreakpoint = 1000;

  final ScrollController scrollController = ScrollController();
  final TextEditingController textFieldController = TextEditingController();

  ValueNotifier<bool> isDisconnected = ValueNotifier(false);

  final ValueNotifier<List<TransferWidget>> _fileTransferWidgets =
      ValueNotifier([]);
  final Map<String, ValueNotifier<double>> _transferProgress = {};
  final Map<String, TransferStatus> _pendingTransferStatuses = {};
  final Map<String, bool> _pendingTransferCanResume = {};
  final Map<String, String> _pendingTransferPausedBy = {};

  bool isSharingInProgress = false;
  bool _sentInitialFiles = false;
  bool _disconnectSignalSent = false;
  bool _leavingPage = false;
  bool _suppressNextConnectionIssueAfterCancellation = false;
  bool _fatalErrorReceived = false;
  String? _fatalErrorReason;
  _SessionIssue? _sessionIssue;

  // The sent files that were interrupted; used to reconnect and resume the
  // whole batch instead of forcing the user to pick multi-gigabyte files again.
  final List<_ResumeTarget> _resumeTargets = [];
  Timer? _resumeTimer;
  bool _resumeInProgress = false;
  bool _pendingResumeAfterConnect = false;
  int _resumeAttempts = 0;
  int _connectionEpoch = 0;

  /// 当前文件请求包含的文件 id（按发送顺序）。请求结束后清空。
  List<String> _requestFileIds = [];

  /// 当前请求是否已被接受；批量请求在文件之间短暂没有“传输中”卡片时仍按传输中处理。
  bool _requestAccepted = false;

  /// 已被暂停的文件 id。排队中的文件也会记录，但卡片保持“排队”，不显示逐文件按键。
  final Set<String> _pausedFileIds = {};

  /// 暂停是否由对端发起；由对端暂停时“全部继续”不可点。
  bool _requestPausedByPeer = false;
  Map<String, dynamic>? _peerInfo;

  StreamSubscription? _streamSubscription;
  StreamSubscription<List<FastFilePickerPath>>? _sharedFilesSubscription;

  @override
  void initState() {
    super.initState();
    _peerInfo = SocketService.instance.connectedPeerInfo;

    _sharedFilesSubscription = IncomingShareService.instance.sharedFilesStream
        .listen((batch) {
          if (!mounted || batch.isEmpty) {
            return;
          }
          if (isDisconnected.value) {
            showScaffoldSnackbar(
              AppLocalizations.of(context).couldNotSendSharedFiles,
            );
            return;
          }
          final locations = <String>[];
          for (final file in batch) {
            final location = _pickedFileLocation(file);
            if (location != null) locations.add(location);
          }
          if (locations.isEmpty) {
            showScaffoldSnackbar(
              AppLocalizations.of(context).couldNotReadSelectedFile,
            );
            return;
          }
          _sendLocations(locations);
          final l10n = AppLocalizations.of(context);
          final peerName = _peerName(context);
          showScaffoldSnackbar(
            batch.length == 1
                ? l10n.sendingSharedFileTo(peerName)
                : l10n.sendingNSharedFilesTo(batch.length, peerName),
          );
        });

    if (widget.initialBatchFiles != null &&
        widget.initialBatchFiles!.isNotEmpty) {
      _requestFileIds = [
        for (final file in widget.initialBatchFiles!)
          if (file['fileId'] is String) file['fileId'] as String,
      ];
      for (final file in widget.initialBatchFiles!) {
        _prepopulateBatchWidget(file);
      }
    }

    _streamSubscription = SocketService.instance.messageStream.listen(
      (message) {
        final status = message['status'] ?? message['command'];

        switch (status) {
          case 'client_connected':
          case 'connected_to_host':
            _handleConnectionEstablished();
            break;
          case 'peer_info':
            if (!mounted) return;
            setState(() {
              _peerInfo = Map<String, dynamic>.from(message);
            });
            break;
          case 'disconnect':
            if (!mounted) return;
            _disconnectSignalSent = true;
            _handleDisconnectAfterCancellationWindow(_connectionEpoch);
            break;
          case 'start':
            if (message['isBatch'] == true) {
              _handleIncomingBatch(message);
              break;
            }
            final fileId = message['fileId'] as String?;
            if (fileId == null) break;

            if (message['pendingAcceptance'] == true) {
              final senderFingerprint =
                  SocketService.instance.connectedPeerInfo?['certFingerprint']
                      as String?;
              _startSingleRequest(fileId);
              if (TrustedDevicesService.instance.isTrusted(senderFingerprint)) {
                SocketService.instance.acceptTransfer(fileId);
                break;
              }
              setState(() {
                isSharingInProgress = true;
              });
              addFileWidget(
                filePath: message['filePath'],
                fileName: message['fileName'],
                fileSize: sizeConvert(
                  (message['fileSize'] as int).toDouble(),
                ),
                uuid: fileId,
                isReceived: true,
                clipboard: message['clipboard'] == true,
                status: TransferStatus.pending,
              );
              break;
            }

            _requestAccepted = true;
            _trackActiveFile(fileId);
            setState(() {
              isSharingInProgress = true;
            });
            addFileWidget(
              filePath: message['filePath'],
              fileName: message['fileName'],
              fileSize: sizeConvert((message['fileSize'] as int).toDouble()),
              uuid: fileId,
              isReceived: true,
              clipboard: message['clipboard'] == true,
              status: TransferStatus.inProgress,
            );
            break;
          case 'progress':
            _setTransferProgress(
              message['fileId'] as String?,
              (message['progress'] as num?)?.toDouble(),
            );
            break;
          case 'completed':
            replaceTransferWidget(
              uuid: message['fileId'] as String?,
              filePath: message['filePath'] as String?,
              fileName: message['fileName'] as String?,
            );
            _disposeTransferProgress(message['fileId'] as String?);

            setState(() {
              isSharingInProgress = false;
            });
            _finishRequestIfSettled();
            break;
          case 'send_start':
            final sendFileId = message['fileId'] as String?;
            if (sendFileId == null) break;
            final needsAccept = message['pendingAcceptance'] == true;
            final sendIsBatch = message['isBatch'] == true;
            if (isSharingInProgress == true &&
                !needsAccept &&
                !_hasTransferWidget(sendFileId)) {
              break;
            }

            if (needsAccept) {
              if (sendIsBatch) {
                if (_requestFileIds.isEmpty) {
                  _requestAccepted = false;
                }
                if (!_requestFileIds.contains(sendFileId)) {
                  _requestFileIds = [..._requestFileIds, sendFileId];
                }
              } else {
                _startSingleRequest(sendFileId);
              }
            } else {
              _requestAccepted = true;
              _trackActiveFile(sendFileId);
            }

            setState(() {
              isSharingInProgress = true;
            });

            final transferStatus = sendIsBatch && needsAccept
                ? TransferStatus.queued
                : needsAccept
                ? TransferStatus.pending
                : TransferStatus.inProgress;
            addFileWidget(
              filePath: message['filePath'] ?? '',
              uuid: sendFileId,
              fileName: message['fileName'] ?? '',
              fileSize: sizeConvert(
                (message['fileSize'] as int?)?.toDouble() ?? 0,
              ),
              isReceived: false,
              clipboard: message['clipboard'] == true,
              status: transferStatus,
            );
            break;
          case 'send_progress':
            _setTransferProgress(
              message['fileId'] as String?,
              (message['progress'] as num?)?.toDouble(),
            );
            break;
          case 'send_complete':
            replaceTransferWidget(uuid: message['fileId'] as String?);
            _disposeTransferProgress(message['fileId'] as String?);

            setState(() {
              isSharingInProgress = false;
            });
            _finishRequestIfSettled();
            break;
          case 'transfer_paused':
            _applyPaused(
              message['fileId'] as String?,
              pausedBy: message['pausedBy'] as String?,
              canResume: message['canResume'] as bool? ?? false,
            );
            break;
          case 'transfer_resumed':
            _applyResumed(message['fileId'] as String?);
            break;
          case 'transfer_accepted':
            _requestAccepted = true;
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'transfer_cancelled':
          case 'transfer_declined':
            _handleRequestCancelled(message['fileId'] as String?);
            break;
          case 'transfer_cancel_ready':
            setState(() {
              isSharingInProgress = false;
            });
            _finishRequestIfSettled();
            if (_suppressNextConnectionIssueAfterCancellation) {
              Future<void>.delayed(const Duration(seconds: 2), () {
                _suppressNextConnectionIssueAfterCancellation = false;
              });
            }
            break;

          case 'error':
            if (!mounted) return;
            final l10n = AppLocalizations.of(context);
            final isFatal = message['fatal'] == 'true';
            final errorText =
                message['message'] as String? ?? l10n.unknownError;
            if (isFatal) {
              if (_pendingResumeAfterConnect) {
                // A reconnect attempt failed; the periodic retry still owns
                // the resume state and will try again.
                _pendingResumeAfterConnect = false;
                _resumeInProgress = false;
                return;
              }
              // 致命错误不再弹窗，只按会话结束处理；原因写进日志便于排查。
              debugPrint('[SESSION] fatal error: $errorText');
              _fatalErrorReceived = true;
              _fatalErrorReason = errorText;
              _reportSessionIssueAfterCancellationWindow(_connectionEpoch);
            } else if (!_fatalErrorReceived) {
              // 会话已经因致命错误结束时，逐文件上报的普通错误不再重复提示。
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    AppLocalizations.of(context).localizeError(errorText),
                  ),
                ),
              );
            }
            break;
        }
      },
    );
    SocketService.instance.replayTransferState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendInitialFiles();
    });
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _streamSubscription?.cancel();
    _sharedFilesSubscription?.cancel();
    for (final notifier in _transferProgress.values) {
      notifier.dispose();
    }
    _transferProgress.clear();
    if (!_disconnectSignalSent) {
      _leavingPage = true;
      SocketService.instance.disconnect();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_disconnectSignalSent) {
          _leavingPage = true;
          _disconnectSignalSent = true;
          SocketService.instance.disconnect();
        }
      },
      child: GestureDetector(
        onTap: () {
          FocusManager.instance.primaryFocus!.unfocus();
        },
        child: Scaffold(
          appBar: AppBar(title: Text(l10n.share)),
          body: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          // 所有平台同一阅读宽度：窗口窄时铺满，窗口很宽时也不再压成
                          // 500 宽的一条窄带，避免桌面端一片留白。
                          constraints: const BoxConstraints(maxWidth: 1100),
                          child: ValueListenableBuilder(
                            valueListenable: _fileTransferWidgets,
                            builder: (context, widgets, child) => ListView(
                              reverse: true,
                              physics: const BouncingScrollPhysics(),
                              controller: scrollController,
                              padding: EdgeInsets.only(bottom: 15),
                              children: [
                                AnimatedSwitcher(
                                  duration: 240.ms,
                                  switchInCurve: Curves.easeOutCubic,
                                  switchOutCurve: Curves.easeInCubic,
                                  transitionBuilder: (child, animation) {
                                    final offsetAnimation = Tween<Offset>(
                                      begin: const Offset(0, 0.02),
                                      end: Offset.zero,
                                    ).animate(animation);
                                    return FadeTransition(
                                      opacity: animation,
                                      child: SlideTransition(
                                        position: offsetAnimation,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: widgets.isEmpty
                                      ? Padding(
                                          key: const ValueKey('empty_state'),
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 20,
                                            horizontal: 20,
                                          ),
                                          child: Card(
                                            child: Padding(
                                              padding: const EdgeInsets.all(20),
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                spacing: 10,
                                                children: [
                                                  Icon(
                                                    Icons.error_outline_rounded,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .inverseSurface,
                                                  ),
                                                  Text(l10n.noFilesSentYet),
                                                ],
                                              ),
                                            ),
                                          ),
                                        )
                                      : Column(
                                          key: const ValueKey('file_list'),
                                          children: widgets,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 0),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1100),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child:
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: ValueListenableBuilder(
                                      valueListenable: isDisconnected,
                                      builder: (context, disconnected, child) =>
                                          ValueListenableBuilder(
                                            valueListenable:
                                                _fileTransferWidgets,
                                            builder: (context, widgets, child) {
                                              final controls = disconnected
                                                  ? null
                                                  : _buildRequestControls();
                                              return Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                spacing: 10,
                                                children: [
                                                  ?controls,
                                                  _buildTransferActions(
                                                    isConnectionLost:
                                                        disconnected,
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                    ),
                                  ),
                                ],
                              ).animate().fadeIn(
                                delay: 80.ms,
                                duration: 220.ms,
                                curve: Curves.easeOutCubic,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint)
                  Container(
                    width: 1,
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.55),
                  ),
                if (MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint)
                  SizedBox(
                    width: 340,
                    child: _buildPeerDetailsPanel(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPeerDetailsPanel() {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final peer = _peerInfo;
    final disconnected = isDisconnected.value;
    final disconnectedColor = colorScheme.onSurfaceVariant;
    final disconnectedContainer = colorScheme.surfaceContainerHighest;

    return ColoredBox(
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AnimatedSwitcher(
          duration: 220.ms,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: peer == null
              ? Column(
                  key: const ValueKey('peer-loading'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 14,
                  children: [
                    const CircularProgressIndicator(),
                    Text(
                      l10n.identifyingConnectedDevice,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                )
              : Column(
                  key: ValueKey(peer['address']),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CircleAvatar(
                      radius: 34,
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      child: Icon(
                        peer['deviceType'] == 'laptop'
                            ? Icons.laptop_rounded
                            : Icons.smartphone_rounded,
                        size: 30,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      peer['name'] as String? ?? l10n.connectedDevice,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 7,
                      children: [
                        Icon(
                          Icons.circle,
                          size: 9,
                          color: disconnected
                              ? disconnectedColor
                              : colorScheme.primary,
                        ),
                        Text(
                          disconnected
                              ? l10n.disconnected
                              : l10n.connected,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: disconnected
                                    ? disconnectedColor
                                    : colorScheme.primary,
                              ),
                        ),
                      ],
                    ),
                    if (disconnected) ...[
                      const SizedBox(height: 16),
                      Card(
                        margin: EdgeInsets.zero,
                        color: disconnectedContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: colorScheme.outlineVariant),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 10,
                            children: [
                              Icon(
                                Icons.link_off_rounded,
                                color: disconnectedColor,
                              ),
                              Expanded(
                                child: Text(
                                  l10n.sessionEndedMessage,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: disconnectedColor,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    _buildPeerDetailRow(
                      icon: Icons.lan_rounded,
                      label: l10n.ipAddress,
                      value: peer['address'] as String? ?? l10n.unknownValue,
                    ),
                    const Divider(height: 28),
                    _buildPeerDetailRow(
                      icon: Icons.numbers_rounded,
                      label: l10n.port,
                      value:
                          (peer['port'] as int?)?.toString() ??
                          l10n.unknownValue,
                    ),
                    const Divider(height: 28),
                    _buildPeerDetailRow(
                      icon: Icons.devices_rounded,
                      label: l10n.device,
                      value: peer['deviceType'] == 'laptop'
                          ? l10n.desktopOrLaptop
                          : l10n.phoneOrTablet,
                    ),
                    const Divider(height: 28),
                    _buildPeerDetailRow(
                      icon: peer['tls'] == true
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      label: l10n.security,
                      value: peer['tls'] == true
                          ? l10n.tlsEnabled
                          : l10n.unencrypted,
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildPeerDetailRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      spacing: 12,
      children: [
        Icon(icon, size: 20, color: colorScheme.onSurfaceVariant),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 底部按键只处理批量请求；单文件的暂停/取消/接收都在文件卡片上。
  ///
  /// - 多文件等待接收：发送方“全部取消”，接收方“全部接收 / 全部拒绝”。
  /// - 多文件正在传输：双方“全部暂停（全部继续）/ 全部取消”。
  Widget? _buildRequestControls() {
    if (!_requestBusy || !_requestIsMulti) {
      return null;
    }
    final l10n = AppLocalizations.of(context);
    if (_requestInTransfer) {
      // 暂停状态由页面记录（排队文件也计入暂停），不再从卡片状态反推。
      final allPaused = _requestPaused;
      // 对方暂停时本端不能继续，按键置灰；本端暂停时显示“全部继续”。
      return _requestButtonRow([
        _requestPrimaryButton(
          icon: allPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: allPaused ? l10n.resumeAll : l10n.pauseAll,
          onPressed: allPaused && _requestPausedByPeer
              ? null
              : _toggleAllPaused,
        ),
        _requestSecondaryButton(
          icon: Icons.close_rounded,
          label: l10n.cancelAll,
          onPressed: _cancelAllTransfers,
        ),
      ]);
    }
    if (_requestIsReceiver) {
      return _requestButtonRow([
        _requestPrimaryButton(
          icon: Icons.download_rounded,
          label: l10n.acceptAll,
          onPressed: _acceptAllRequest,
        ),
        _requestSecondaryButton(
          icon: Icons.block_rounded,
          label: l10n.declineAll,
          onPressed: _declineAllRequest,
        ),
      ]);
    }
    return _requestButtonRow([
      _requestSecondaryButton(
        icon: Icons.close_rounded,
        label: l10n.cancelAll,
        onPressed: _cancelRequest,
      ),
    ]);
  }

  Widget _requestButtonRow(List<Widget> buttons) {
    return Row(
      spacing: 10,
      children: [for (final button in buttons) Expanded(child: button)],
    );
  }

  Widget _requestPrimaryButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
    );
  }

  Widget _requestSecondaryButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
    );
  }

  /// Turns the raw socket/protocol error into a short, actionable subtitle.
  String _issueSubtitle(AppLocalizations l10n) {
    final reason = _fatalErrorReason;
    if (reason == null || reason.isEmpty) {
      return l10n.reconnectToSendMore;
    }
    final lower = reason.toLowerCase();
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    if (lower.contains('errno = 103') ||
        lower.contains('errno = 101') ||
        lower.contains('software caused connection abort') ||
        lower.contains('network is unreachable')) {
      return isZh ? '网络连接中断，可继续传输' : 'Network connection lost; resume to continue.';
    }
    if (lower.contains('heartbeat')) {
      return isZh ? '连接超时，可继续传输' : 'Connection timed out; resume to continue.';
    }
    if (lower.contains('incomplete') || lower.contains('size mismatch')) {
      return isZh ? '文件大小校验失败，需要重新传输' : 'File size verification failed. Send it again.';
    }
    if (lower.contains('save received file') ||
        lower.contains('prepare file')) {
      return isZh ? '接收方保存文件失败' : 'The receiver could not save the file.';
    }
    final singleLine = reason.replaceAll('\n', ' ').trim();
    return singleLine.length <= 90
        ? singleLine
        : '${singleLine.substring(0, 90)}…';
  }

  /// 空闲时显示三个发送入口；连接断开、传输中、等待批准时显示状态区。
  ///
  /// 连接断开后直接显示结果：打断过未完成的传输时显示“传输被中断”，
  /// 传输都已结束时显示“连接已断开”。
  Widget _buildTransferActions({required bool isConnectionLost}) {
    final l10n = AppLocalizations.of(context);
    if (isConnectionLost) {
      final interrupted = _sessionIssue == _SessionIssue.transferInterrupted;
      final status = _buildTransferStatusButton(
        icon: interrupted
            ? Icons.sync_problem_rounded
            : Icons.link_off_rounded,
        title: interrupted ? l10n.transferInterrupted : l10n.connectionLost,
        subtitle: _issueSubtitle(l10n),
        disconnected: true,
      );
      if (!interrupted || _resumeTargets.isEmpty) {
        return status;
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          status,
          const SizedBox(height: 8),
          _requestPrimaryButton(
            icon: Icons.play_arrow_rounded,
            label: l10n.continueAction,
            onPressed: _resumeInProgress
                ? null
                : () => unawaited(_resumeTransfer()),
          ),
        ],
      );
    }
    if (_requestInTransfer) {
      final allPaused = _requestPaused;
      // 本端发起的暂停能自己继续；对方暂停时只能等对方继续。
      return _buildTransferStatusButton(
        icon: allPaused
            ? Icons.pause_circle_outline_rounded
            : Icons.hourglass_top_rounded,
        title: allPaused ? l10n.transferPaused : l10n.transferInProgress,
        subtitle: !allPaused
            ? l10n.waitForTransferToFinish
            : _requestPausedByPeer
            ? l10n.transferPausedWaiting
            : l10n.transferPausedHint,
        disconnected: false,
      );
    }
    if (_requestBusy) {
      // 等待接收方批准或等待接收：底部只放请求按键，不显示发送入口。
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;

    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 62),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Icon(icon, size: 22, color: colorScheme.primary),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        action(
          icon: Icons.content_paste_rounded,
          label: l10n.clipboard,
          onTap: _sendClipboard,
        ),
        const SizedBox(width: 8),
        action(
          icon: Icons.file_present_rounded,
          label: l10n.file,
          onTap: _pickFilesToSend,
        ),
        const SizedBox(width: 8),
        action(
          icon: Icons.folder_open_rounded,
          label: l10n.folder,
          onTap: _sendFolder,
        ),
      ],
    );
  }

  /// 传输中或连接断开时替代三个入口的状态按键，不可点击。
  Widget _buildTransferStatusButton({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool disconnected,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: disconnected ? colorScheme.outlineVariant : Colors.transparent,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        child: Row(
          spacing: 12,
          children: [
            Icon(
              icon,
              color: disconnected
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.primary,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: disconnected
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showScaffoldSnackbar(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  void _sendInitialFiles() {
    if (_sentInitialFiles || widget.initialFiles.isEmpty) {
      return;
    }

    _sentInitialFiles = true;
    final locations = <String>[];
    for (final file in widget.initialFiles) {
      final location = _pickedFileLocation(file);
      if (location != null) locations.add(location);
    }
    _sendLocations(locations);
  }

  String _peerName(BuildContext context) {
    final name = _peerInfo?['name'] as String?;
    return (name == null || name.isEmpty)
        ? AppLocalizations.of(context).peer
        : name;
  }

  /// 选择器返回的路径转换成传输层可用的位置：Android 用 SAF 的 content://，其余用文件路径。
  String? _pickedFileLocation(FastFilePickerPath pickedFile) {
    return Platform.isAndroid && pickedFile.uri != null
        ? pickedFile.uri
        : pickedFile.path;
  }

  /// 一个文件走单文件请求；多个文件合成一次批量请求，接收方一次批准整批。
  void _sendLocations(List<String> locations) {
    if (locations.isEmpty) {
      return;
    }
    if (locations.length == 1) {
      SocketService.instance.sendFile(locations.first);
      return;
    }
    SocketService.instance.sendFiles(locations);
  }

  /// 多选文件后发送：选一个发单文件请求，选多个发一次批量请求。
  Future<void> _pickFilesToSend() async {
    // Android 用系统文档选择器拿 content:// URI，不再经过会复制整个文件的插件。
    final pickedFiles = Platform.isAndroid
        ? await AndroidDocumentService.instance.pickDocuments()
        : await FastFilePicker.pickMultipleFiles() ??
              const <FastFilePickerPath>[];
    if (!mounted || pickedFiles.isEmpty) return;

    final locations = <String>[];
    for (final pickedFile in pickedFiles) {
      final location = _pickedFileLocation(pickedFile);
      if (location != null) locations.add(location);
    }
    if (locations.isEmpty) {
      showScaffoldSnackbar(
        AppLocalizations.of(context).couldNotReadSelectedFile,
      );
      return;
    }
    _sendLocations(locations);
  }

  /// 把粘贴板文本写成临时文件后按普通文件发送，接收端会写回粘贴板。
  Future<void> _sendClipboard() async {
    final l10n = AppLocalizations.of(context);
    final file = await createClipboardTextFile();
    if (!mounted) return;
    if (file == null) {
      showScaffoldSnackbar(l10n.clipboardEmpty);
      return;
    }
    SocketService.instance.sendFile(
      file.path,
      displayName: l10n.clipboardFileName,
      clipboard: true,
    );
  }

  /// 选择文件夹并把其中的文件作为一次批量请求发送。
  Future<void> _sendFolder() async {
    final l10n = AppLocalizations.of(context);
    try {
      if (Platform.isAndroid) {
        final pickedDirectory = await AndroidSafService.pickDirectory(
          writePermission: false,
        );
        if (pickedDirectory == null) return;
        final documents = await AndroidSafService.listFilesUnder(
          pickedDirectory.uri,
        );
        if (!mounted) return;
        if (documents.isEmpty) {
          showScaffoldSnackbar(l10n.noFilesInSelectedFolder);
          return;
        }
        _sendLocations([for (final document in documents) document.uri]);
        return;
      }

      final pickedFolder = await FastFilePicker.pickFolder(
        writePermission: false,
      );
      final folderPath = pickedFolder?.path;
      if (folderPath == null || folderPath.isEmpty) return;
      final directory = Directory(folderPath);
      if (!await directory.exists()) {
        if (mounted) {
          showScaffoldSnackbar(l10n.folderNotFound);
        }
        return;
      }

      final paths = <String>[];
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          paths.add(entity.path);
        }
      }
      if (paths.isEmpty) {
        if (mounted) {
          showScaffoldSnackbar(l10n.noFilesInSelectedFolder);
        }
        return;
      }
      _sendLocations(paths);
    } catch (_) {
      if (mounted) {
        showScaffoldSnackbar(l10n.cannotReadFolder);
      }
    }
  }

  /// 列表里是否还有没结束的传输（排队、待批准、传输中或已暂停）。
  bool _hasUnfinishedTransfers() {
    return _fileTransferWidgets.value.any(
      (widget) =>
          widget.status != TransferStatus.completed &&
          widget.status != TransferStatus.cancelled,
    );
  }

  /// 记录会话异常结束，底部发送入口据此显示断开原因。
  ///
  /// 仍有未结束的传输时说明这次断开打断了传输；传输都已完成或取消时，
  /// 只是连接断开。结果只记一次，之后重复的断开不再改变显示。
  void _reportSessionIssue() {
    if (!mounted) return;

    final interrupted = isSharingInProgress || _hasUnfinishedTransfers();
    if (interrupted) {
      _resumeTargets.clear();
      for (final widget in _fileTransferWidgets.value) {
        if (!widget.isReceived &&
            !widget.clipboard &&
            widget.filePath.isNotEmpty &&
            widget.status != TransferStatus.completed &&
            widget.status != TransferStatus.cancelled) {
          _resumeTargets.add(
            _ResumeTarget(
              path: widget.filePath,
              name: widget.fileName,
              uuid: widget.uuid,
            ),
          );
        }
      }
    }
    setState(() {
      isSharingInProgress = false;
      _sessionIssue ??= interrupted
          ? _SessionIssue.transferInterrupted
          : _SessionIssue.connectionLost;
    });
    isDisconnected.value = true;
    if (_resumeTargets.isNotEmpty && !_leavingPage && !_disconnectSignalSent) {
      _scheduleResume();
    }
  }

  /// Reconnects to the same peer and lets the isolate offer the files again.
  ///
  /// The receiver keeps a partial file per resume key, so every interrupted
  /// file of a batch continues from the offset it reports.
  Future<void> _resumeTransfer() async {
    if (_resumeTargets.isEmpty || _resumeInProgress || _pendingResumeAfterConnect) {
      return;
    }
    final peer = _peerInfo;
    final address = peer?['address'] as String?;
    if (address == null) {
      return;
    }

    final port = (peer?['port'] as num?)?.toInt() ?? 8050;
    final useTls = peer?['tls'] == true;
    final fingerprint = peer?['certFingerprint'] as String?;
    _resumeInProgress = true;
    _pendingResumeAfterConnect = true;
    try {
      await SocketService.instance.connectToHost(
        address,
        port: port,
        useTLS: useTls,
        expectedCertificateFingerprint: useTls ? fingerprint : null,
        trustedPeerId: useTls ? fingerprint : null,
      );
      // If the connection event never arrives, allow the next retry.
      unawaited(
        Future<void>.delayed(const Duration(seconds: 12), () {
          if (!mounted || !_pendingResumeAfterConnect) {
            return;
          }
          _pendingResumeAfterConnect = false;
          _resumeInProgress = false;
        }),
      );
    } catch (_) {
      _pendingResumeAfterConnect = false;
      _resumeInProgress = false;
    }
  }

  void _scheduleResume() {
    _resumeTimer?.cancel();
    if (_resumeTargets.isEmpty) {
      return;
    }
    _resumeAttempts = 0;
    _resumeTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!mounted || _leavingPage || _resumeTargets.isEmpty) {
        timer.cancel();
        return;
      }
      if (_resumeInProgress || _pendingResumeAfterConnect) {
        return;
      }
      _resumeAttempts++;
      if (_resumeAttempts > 20) {
        timer.cancel();
        return;
      }
      unawaited(_resumeTransfer());
    });
  }

  /// Handles a fresh connection and resumes every interrupted sent file once.
  void _handleConnectionEstablished() {
    if (!mounted) {
      return;
    }
    _connectionEpoch++;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _resumeInProgress = false;
    _disconnectSignalSent = false;
    final shouldSendResume =
        _pendingResumeAfterConnect && _resumeTargets.isNotEmpty;
    _pendingResumeAfterConnect = false;

    if (isDisconnected.value || _sessionIssue != null || _fatalErrorReceived) {
      setState(() {
        _sessionIssue = null;
        _fatalErrorReceived = false;
        _fatalErrorReason = null;
      });
      isDisconnected.value = false;
    }

    if (!shouldSendResume) {
      // A normal new connection: drop any stale resume targets so a later
      // disconnect cannot resurrect old files.
      _resumeTargets.clear();
      return;
    }

    final targets = List<_ResumeTarget>.of(_resumeTargets);
    _resumeTargets.clear();
    // 续传会建立新的请求 id，旧的请求记录一并清掉，避免底部按键按旧集合判断。
    _requestFileIds = [];
    _requestAccepted = false;
    final resumedIds = {for (final target in targets) target.uuid};
    _fileTransferWidgets.value = _fileTransferWidgets.value
        .where((widget) => !resumedIds.contains(widget.uuid))
        .toList();
    for (final uuid in resumedIds) {
      _transferProgress.remove(uuid)?.dispose();
      _pendingTransferStatuses.remove(uuid);
      _pendingTransferCanResume.remove(uuid);
      _pendingTransferPausedBy.remove(uuid);
      _pausedFileIds.remove(uuid);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leavingPage) {
        return;
      }
      // 逐文件重新发起；连续的 send_file 会被引擎合并成一次批量请求。
      for (final target in targets) {
        SocketService.instance.sendFile(
          target.path,
          displayName: target.name,
        );
      }
    });
  }

  void replaceTransferWidget({
    required String? uuid,
    String? filePath,
    String? fileName,
  }) {
    if (uuid == null) {
      return;
    }
    var found = false;
    _fileTransferWidgets.value = _fileTransferWidgets.value.map((widget) {
      if (widget.uuid == uuid) {
        found = true;
        return TransferWidget(
          key: ValueKey(widget.uuid),
          filePath: filePath ?? widget.filePath,
          fileName: fileName ?? widget.fileName,
          fileSize: widget.fileSize,
          isReceived: widget.isReceived,
          clipboard: widget.clipboard,
          uuid: widget.uuid,
          value: null,
          status: TransferStatus.completed,
          canResume: true,
          onCancelQueued: () => _cancelQueuedFile(widget.uuid),
        );
      }
      return widget;
    }).toList();
    if (!found) {
      _pendingTransferStatuses[uuid] = TransferStatus.completed;
    }
  }

  void _updateTransferStatus(
    String? uuid,
    TransferStatus status, {
    String? pausedBy,
    bool canResume = true,
  }) {
    if (uuid == null) {
      return;
    }

    final widgets = _fileTransferWidgets.value;
    var didUpdate = false;
    _fileTransferWidgets.value = [
      for (final widget in widgets)
        if (widget.uuid == uuid) ...[
          if (widget.status == TransferStatus.completed ||
              widget.status == TransferStatus.cancelled)
            widget
          else
            _copyTransferWidget(
              widget,
              status: status,
              canResume: pausedBy == null
                  ? canResume
                  : _transferRole(widget.isReceived) == pausedBy,
              value: status == TransferStatus.completed ? null : widget.value,
            ),
        ] else
          widget,
    ];
    didUpdate = widgets.any((widget) => widget.uuid == uuid);
    if (didUpdate) {
      _pendingTransferStatuses.remove(uuid);
      _pendingTransferCanResume.remove(uuid);
      _pendingTransferPausedBy.remove(uuid);
      return;
    }

    if (_pendingTransferStatuses[uuid] != TransferStatus.completed &&
        _pendingTransferStatuses[uuid] != TransferStatus.cancelled) {
      _pendingTransferStatuses[uuid] = status;
      _pendingTransferCanResume[uuid] = canResume;
      if (pausedBy == null) {
        _pendingTransferPausedBy.remove(uuid);
      } else {
        _pendingTransferPausedBy[uuid] = pausedBy;
      }
    }
  }

  /// 暂停回执只把真正在传输的卡片改成“已暂停”，排队卡保持排队。
  ///
  /// 批量暂停会逐个文件下发，引擎对排队文件也会回执；如果让排队卡跟着变成
  /// paused，卡片会凭空长出“继续/取消”按键，取消或继续后还会被误标成传输中。
  void _applyPaused(
    String? uuid, {
    String? pausedBy,
    bool canResume = false,
  }) {
    if (uuid == null || !mounted) {
      return;
    }
    _pausedFileIds.add(uuid);
    if (pausedBy != null) {
      _requestPausedByPeer = pausedBy != _localTransferRole;
    }
    final widget = _widgetFor(uuid);
    if (widget == null || widget.status != TransferStatus.inProgress) {
      return;
    }
    _updateTransferStatus(
      uuid,
      TransferStatus.paused,
      pausedBy: pausedBy,
      canResume: canResume,
    );
  }

  /// 继续回执只恢复已暂停的卡片；排队卡等自己的 send_start 再进入传输中。
  void _applyResumed(String? uuid) {
    if (uuid == null || !mounted) {
      return;
    }
    _pausedFileIds.remove(uuid);
    if (_pausedFileIds.isEmpty) {
      _requestPausedByPeer = false;
    }
    final widget = _widgetFor(uuid);
    if (widget == null || widget.status != TransferStatus.paused) {
      return;
    }
    _updateTransferStatus(uuid, TransferStatus.inProgress);
  }

  TransferWidget? _widgetFor(String uuid) {
    for (final widget in _fileTransferWidgets.value) {
      if (widget.uuid == uuid) {
        return widget;
      }
    }
    return null;
  }

  /// 请求内卡片的显示角色，用于区分本端与对端发起的暂停。
  String get _localTransferRole {
    final widgets = _requestWidgets;
    if (widgets.isEmpty) {
      return 'sender';
    }
    return _transferRole(widgets.first.isReceived);
  }

  void _prepopulateBatchWidget(Map<String, dynamic> file) {
    final uuid = file['fileId'] as String?;
    final fileName = file['fileName'] as String?;
    final fileSize = file['fileSize'] as int?;
    if (uuid == null || fileName == null || fileSize == null) return;
    final progress = ValueNotifier<double>(0);
    _transferProgress[uuid] = progress;
    _fileTransferWidgets.value = [
      ..._fileTransferWidgets.value,
      TransferWidget(
        key: ValueKey(uuid),
        filePath: '',
        fileName: fileName,
        fileSize: sizeConvert(fileSize.toDouble()),
        value: progress,
        isReceived: true,
        clipboard: file['clipboard'] == true,
        uuid: uuid,
        status: TransferStatus.queued,
        canResume: true,
        onPause: () =>
            SocketService.instance.pauseTransfer(uuid, isReceiver: true),
        onResume: () =>
            SocketService.instance.resumeTransfer(uuid, isReceiver: true),
        onCancel: () => _cancelTransfer(uuid, isReceived: true),
        onAccept: () => SocketService.instance.acceptTransfer(uuid),
        onDecline: () => SocketService.instance.declineTransfer(uuid),
        onCancelQueued: () => _cancelQueuedFile(uuid),
      ),
    ];
  }

  void addFileWidget({
    required String uuid,
    required String fileName,
    required String fileSize,
    required String filePath,
    required bool isReceived,
    bool clipboard = false,
    TransferStatus status = TransferStatus.inProgress,
    VoidCallback? onAccept,
    VoidCallback? onDecline,
  }) {
    if (_fileTransferWidgets.value.any((widget) => widget.uuid == uuid)) {
      _fileTransferWidgets.value = [
        for (final widget in _fileTransferWidgets.value)
          widget.uuid == uuid
              ? _copyTransferWidget(
                  widget,
                  status: status,
                  filePath: filePath.isEmpty ? widget.filePath : filePath,
                  fileName: fileName,
                  value: widget.value,
                )
              : widget,
      ];
      return;
    }
    final progress = ValueNotifier<double>(0);
    _transferProgress[uuid] = progress;
    final hadPendingStatus = _pendingTransferStatuses.containsKey(uuid);
    final pendingStatus =
        _pendingTransferStatuses.remove(uuid) ?? TransferStatus.inProgress;
    final pendingPausedBy = _pendingTransferPausedBy.remove(uuid);
    final pendingCanResumeFallback = _pendingTransferCanResume.remove(uuid);
    final pendingCanResume = pendingPausedBy == null
        ? pendingCanResumeFallback ?? true
        : _transferRole(isReceived) == pendingPausedBy;
    _fileTransferWidgets.value = [
      ..._fileTransferWidgets.value,
      TransferWidget(
        key: ValueKey(uuid),
        filePath: filePath,
        fileName: fileName,
        fileSize: fileSize,
        value: progress,
        isReceived: isReceived,
        clipboard: clipboard,
        uuid: uuid,
        status: hadPendingStatus ? pendingStatus : status,
        canResume: pendingCanResume,
        onPause: () =>
            SocketService.instance.pauseTransfer(uuid, isReceiver: isReceived),
        onResume: () =>
            SocketService.instance.resumeTransfer(uuid, isReceiver: isReceived),
        onCancel: () => _cancelTransfer(uuid, isReceived: isReceived),
        onAccept: onAccept ?? () => SocketService.instance.acceptTransfer(uuid),
        onDecline:
            onDecline ?? () => SocketService.instance.declineTransfer(uuid),
        onCancelQueued: () => _cancelQueuedFile(uuid),
      ),
    ];
  }

  bool _hasTransferWidget(String? uuid) {
    if (uuid == null) {
      return false;
    }
    return _fileTransferWidgets.value.any((widget) => widget.uuid == uuid);
  }

  void _setTransferProgress(String? uuid, double? progress) {
    if (uuid == null || progress == null) {
      return;
    }
    _transferProgress[uuid]?.value = progress.clamp(0.0, 1.0);
  }

  void _disposeTransferProgress(String? uuid) {
    if (uuid == null) {
      return;
    }
    final notifier = _transferProgress.remove(uuid);
    Future<void>.delayed(const Duration(milliseconds: 500), notifier?.dispose);
  }

  TransferWidget _copyTransferWidget(
    TransferWidget widget, {
    required TransferStatus status,
    bool canResume = true,
    String? filePath,
    String? fileName,
    ValueListenable<double>? value,
  }) {
    return TransferWidget(
      key: ValueKey(widget.uuid),
      filePath: filePath ?? widget.filePath,
      fileName: fileName ?? widget.fileName,
      fileSize: widget.fileSize,
      isReceived: widget.isReceived,
      clipboard: widget.clipboard,
      uuid: widget.uuid,
      value: value,
      status: status,
      canResume: canResume,
      onPause: () => SocketService.instance.pauseTransfer(
        widget.uuid,
        isReceiver: widget.isReceived,
      ),
      onResume: () => SocketService.instance.resumeTransfer(
        widget.uuid,
        isReceiver: widget.isReceived,
      ),
      onCancel: () =>
          _cancelTransfer(widget.uuid, isReceived: widget.isReceived),
      onAccept: () => SocketService.instance.acceptTransfer(widget.uuid),
      onDecline: () => SocketService.instance.declineTransfer(widget.uuid),
      onCancelQueued: () => _cancelQueuedFile(widget.uuid),
    );
  }

  String _transferRole(bool isReceived) {
    return isReceived ? 'receiver' : 'sender';
  }

  void _cancelTransfer(String fileId, {required bool isReceived}) {
    if (!isReceived) {
      _suppressNextConnectionIssueAfterCancellation = true;
    }
    SocketService.instance.cancelTransfer(fileId);
  }

  /// 取消排队中的单个文件。
  ///
  /// 只有在整批还没开始（第一个文件仍是 pending/queued）时，取消第一个文件才
  /// 等同于取消整批；一旦第一个文件已经开始传输，其余文件都只取消自己。
  void _cancelQueuedFile(String uuid) {
    final widget = _widgetFor(uuid);
    if (widget == null) {
      return;
    }
    final headId = _requestFileIds.isEmpty ? null : _requestFileIds.first;
    final head = headId == null ? null : _widgetFor(headId);
    final headNotStarted =
        head != null &&
        (head.status == TransferStatus.pending ||
            head.status == TransferStatus.queued);
    if (uuid == headId && headNotStarted) {
      if (_requestIsReceiver) {
        _declineAllRequest();
      } else {
        _cancelRequest();
      }
      return;
    }
    _cancelTransfer(uuid, isReceived: widget.isReceived);
  }

  /// 本请求是否处于暂停状态（含排队文件）。
  bool get _requestPaused =>
      _pausedFileIds.isNotEmpty && _requestHasUnfinished;

  bool get _requestHasUnfinished => _requestWidgets.any(
    (widget) =>
        widget.status != TransferStatus.completed &&
        widget.status != TransferStatus.cancelled,
  );

  /// 全部暂停与全部继续的切换。
  void _toggleAllPaused() {
    final widgets = _requestWidgets;
    final resume = _pausedFileIds.isNotEmpty;
    for (final widget in widgets) {
      if (widget.status == TransferStatus.completed ||
          widget.status == TransferStatus.cancelled) {
        continue;
      }
      if (resume) {
        SocketService.instance.resumeTransfer(
          widget.uuid,
          isReceiver: widget.isReceived,
        );
      } else {
        SocketService.instance.pauseTransfer(
          widget.uuid,
          isReceiver: widget.isReceived,
        );
      }
    }

    setState(() {
      if (resume) {
        _pausedFileIds.clear();
        _requestPausedByPeer = false;
      } else {
        _requestPausedByPeer = false;
        for (final widget in widgets) {
          if (widget.status == TransferStatus.completed ||
              widget.status == TransferStatus.cancelled) {
            continue;
          }
          _pausedFileIds.add(widget.uuid);
        }
      }
    });
  }

  /// 取消当前请求里尚未结束的传输；发送方向按用户取消处理。
  ///
  /// 点击后立即把卡片标成已取消并收尾，不依赖对端回执，避免界面停在“传输进行中”。
  void _cancelAllTransfers() {
    // 先丢弃还没开始发送的排队文件，避免取消后它们又一个个发出去。
    SocketService.instance.cancelQueuedSends();
    for (final widget in _requestWidgets) {
      if (widget.status == TransferStatus.completed ||
          widget.status == TransferStatus.cancelled) {
        continue;
      }
      _cancelTransfer(widget.uuid, isReceived: widget.isReceived);
    }
    _cancelRequestCards();
  }

  /// 当前请求的文件卡片：优先按记录的请求 id；记录缺失时退回所有未结束的卡片。
  List<TransferWidget> get _requestWidgets {
    final ids = _requestFileIds.toSet();
    final matched = [
      for (final widget in _fileTransferWidgets.value)
        if (ids.contains(widget.uuid)) widget,
    ];
    if (matched.isNotEmpty) {
      return matched;
    }
    return [
      for (final widget in _fileTransferWidgets.value)
        if (widget.status == TransferStatus.pending ||
            widget.status == TransferStatus.queued ||
            widget.status == TransferStatus.inProgress ||
            widget.status == TransferStatus.paused)
          widget,
    ];
  }

  bool get _requestHasActive => _requestWidgets.any(
    (widget) =>
        widget.status == TransferStatus.inProgress ||
        widget.status == TransferStatus.paused,
  );

  /// 当前请求是否处于传输阶段：已接受但文件之间短暂没有传输中卡片时也算。
  bool get _requestInTransfer =>
      _requestHasActive || (_requestAccepted && _requestHasPending);

  bool get _requestHasPending => _requestWidgets.any(
    (widget) =>
        widget.status == TransferStatus.pending ||
        widget.status == TransferStatus.queued,
  );

  bool get _requestBusy => _requestHasPending || _requestHasActive;

  bool get _requestIsMulti =>
      _requestFileIds.length > 1 || _requestWidgets.length > 1;

  bool get _requestIsReceiver =>
      _requestWidgets.isNotEmpty && _requestWidgets.first.isReceived;

  /// 请求里第一个待接收/待批准的文件；批量请求用它代表整批。
  String? get _pendingRequestFileId {
    for (final widget in _requestWidgets) {
      if (widget.status == TransferStatus.pending ||
          widget.status == TransferStatus.queued) {
        return widget.uuid;
      }
    }
    return _requestFileIds.isEmpty ? null : _requestFileIds.first;
  }

  /// 单文件请求：请求里只有这个文件。
  void _startSingleRequest(String fileId) {
    _requestFileIds = [fileId];
  }

  /// 文件开始传输：请求里没有记录时补上，保证底部按当前请求显示。
  void _trackActiveFile(String fileId) {
    if (_requestFileIds.contains(fileId)) {
      return;
    }
    _requestFileIds = [fileId];
  }

  /// 请求全部完成或取消后清空，底部恢复发送入口。
  void _finishRequestIfSettled() {
    if (_requestBusy) {
      return;
    }
    if (_requestFileIds.isEmpty &&
        !_requestAccepted &&
        !isSharingInProgress) {
      return;
    }
    setState(() {
      _requestFileIds = [];
      _requestAccepted = false;
      _pausedFileIds.clear();
      _requestPausedByPeer = false;
      isSharingInProgress = false;
    });
  }

  /// 会话页里直接收到批量请求（file_batch）时，为整批建卡片并等待“全部接收”。
  void _handleIncomingBatch(Map<String, dynamic> message) {
    final rawFiles = message['files'];
    if (rawFiles is! List || rawFiles.isEmpty) {
      return;
    }
    final files = <Map<String, dynamic>>[];
    for (final file in rawFiles) {
      if (file is Map && file['fileId'] is String) {
        files.add(Map<String, dynamic>.from(file));
      }
    }
    if (files.isEmpty) {
      return;
    }

    final fileIds = [for (final file in files) file['fileId'] as String];
    final senderFingerprint = SocketService.instance
        .connectedPeerInfo?['certFingerprint'] as String?;
    final trusted = TrustedDevicesService.instance.isTrusted(senderFingerprint);

    setState(() {
      _requestFileIds = fileIds;
      _requestAccepted = false;
      isSharingInProgress = true;
    });
    for (final file in files) {
      // 批量请求的每张卡片都提供“接收/拒绝”，点哪一张都作用于整批。
      addFileWidget(
        filePath: '',
        fileName: (file['fileName'] as String?) ?? '',
        fileSize: sizeConvert(((file['fileSize'] as int?) ?? 0).toDouble()),
        uuid: file['fileId'] as String,
        isReceived: true,
        clipboard: file['clipboard'] == true,
        status: TransferStatus.pending,
        onAccept: _acceptAllRequest,
        onDecline: _declineAllRequest,
      );
    }
    if (trusted) {
      SocketService.instance.acceptTransfer(fileIds.first);
    }
  }

  /// 请求被拒绝或被取消：批量请求的第一个文件结束即视为整批结束。
  void _handleRequestCancelled(String? fileId) {
    if (fileId == null) {
      return;
    }
    _updateTransferStatus(fileId, TransferStatus.cancelled);
    final firstId = _requestFileIds.isEmpty ? null : _requestFileIds.first;
    if (_requestIsMulti && firstId == fileId) {
      _cancelRequestCards();
      return;
    }
    _finishRequestIfSettled();
  }

  /// 接收方“全部接收”：接受批量请求的第一个文件，发送方随后依次发送整批。
  void _acceptAllRequest() {
    final fileId = _pendingRequestFileId;
    if (fileId == null) {
      return;
    }
    setState(() {
      _requestAccepted = true;
    });
    // 其余待接收卡片转为排队，避免接受后还能重复点“接收”。
    for (final widget in _requestWidgets) {
      if (widget.status == TransferStatus.pending) {
        _updateTransferStatus(widget.uuid, TransferStatus.queued);
      }
    }
    SocketService.instance.acceptTransfer(fileId);
  }

  /// 接收方“全部拒绝”：逐个拒绝整批文件，发送方随之放弃整批。
  void _declineAllRequest() {
    final fileIds = [
      for (final widget in _requestWidgets)
        if (widget.status == TransferStatus.pending ||
            widget.status == TransferStatus.queued)
          widget.uuid,
    ];
    final targets = fileIds.isEmpty ? _requestFileIds : fileIds;
    for (final fileId in targets) {
      SocketService.instance.declineTransfer(fileId);
    }
    _cancelRequestCards();
  }

  /// 发送方“全部取消”：结束当前请求，整批随之作废。
  void _cancelRequest() {
    if (_pendingRequestFileId == null || !_requestIsMulti) {
      return;
    }
    _cancelAllTransfers();
  }

  /// 把当前请求剩下的卡片标记为已取消，避免界面停在等待状态。
  void _cancelRequestCards() {
    for (final widget in _requestWidgets) {
      _updateTransferStatus(widget.uuid, TransferStatus.cancelled);
    }
    setState(() {
      _requestAccepted = false;
      _pausedFileIds.clear();
      _requestPausedByPeer = false;
      isSharingInProgress = false;
    });
    _finishRequestIfSettled();
  }

  Future<void> _handleDisconnectAfterCancellationWindow(int epoch) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || epoch != _connectionEpoch) {
      return;
    }
    if (_suppressNextConnectionIssueAfterCancellation) {
      if (mounted) {
        isDisconnected.value = true;
      }
      return;
    }
    if (!_leavingPage &&
        (_resumeTargets.isNotEmpty ||
            _resumeInProgress ||
            _pendingResumeAfterConnect)) {
      // A resume attempt deliberately stops the previous isolate; that
      // internal disconnect must not pop the page.
      isDisconnected.value = true;
      return;
    }
    if (!_leavingPage &&
        (_sessionIssue != null || _hasUnfinishedTransfers())) {
      // A receive session that already reported an interruption, or a page
      // that still has unfinished cards, must stay open for the reconnect.
      isDisconnected.value = true;
      return;
    }
    if (!_leavingPage && isSharingInProgress) {
      // 传输中被主动断开：日志用来区分“有人调用了断开”和“心跳/写失败”。
      debugPrint('[SESSION] disconnect while transferring');
      _reportSessionIssue();
    } else if (!_leavingPage) {
      Navigator.pop(context);
      showScaffoldSnackbar(
        AppLocalizations.of(context).disconnectedSnackbar,
      );
    }
  }

  /// 用户主动取消后的宽限期内不报异常，避免把取消引起的断开算成传输中断。
  Future<void> _reportSessionIssueAfterCancellationWindow(int epoch) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted ||
        epoch != _connectionEpoch ||
        _disconnectSignalSent ||
        _suppressNextConnectionIssueAfterCancellation) {
      return;
    }
    _reportSessionIssue();
  }

  String sizeConvert(double bytes) {
    if (bytes.isNaN || bytes.isInfinite || bytes <= 0) return '0 B';

    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    int unitIndex = 0;
    double size = bytes;

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    String formatted;
    if (unitIndex == 0) {
      formatted = '${size.toInt()} ${units[unitIndex]}';
    } else if (size < 10) {
      formatted = '${size.toStringAsFixed(2)} ${units[unitIndex]}';
    } else if (size < 100) {
      formatted = '${size.toStringAsFixed(1)} ${units[unitIndex]}';
    } else {
      formatted = '${size.toStringAsFixed(0)} ${units[unitIndex]}';
    }

    return formatted;
  }
}

/// 断线续传目标：被中断的单个已发送文件。
class _ResumeTarget {
  const _ResumeTarget({
    required this.path,
    required this.name,
    required this.uuid,
  });

  final String path;
  final String name;
  final String uuid;
}
