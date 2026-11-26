import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flashbyte/services/security/trusted_devices_service.dart';
import 'package:flashbyte/services/sharing/incoming_share_service.dart';
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
  _SessionIssue? _sessionIssue;
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
          SocketService.instance.sendFilesSeparately(locations);
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
      for (final file in widget.initialBatchFiles!) {
        _prepopulateBatchWidget(file);
      }
    }

    _streamSubscription = SocketService.instance.messageStream.listen(
      (message) {
        final status = message['status'] ?? message['command'];

        switch (status) {
          case 'peer_info':
            if (!mounted) return;
            setState(() {
              _peerInfo = Map<String, dynamic>.from(message);
            });
            break;
          case 'disconnect':
            if (!mounted) return;
            _disconnectSignalSent = true;
            _handleDisconnectAfterCancellationWindow();
            break;
          case 'start':
            if (message['isBatch'] == true) break;
            final fileId = message['fileId'] as String?;
            if (fileId == null) break;

            if (message['pendingAcceptance'] == true) {
              final senderFingerprint =
                  SocketService.instance.connectedPeerInfo?['certFingerprint']
                      as String?;
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
            break;
          case 'send_start':
            final sendFileId = message['fileId'] as String?;
            if (sendFileId == null) break;
            if (isSharingInProgress == true &&
                message['pendingAcceptance'] != true &&
                !_hasTransferWidget(sendFileId)) {
              break;
            }

            setState(() {
              isSharingInProgress = true;
            });

            final isBatch = message['isBatch'] == true;
            final needsAccept = message['pendingAcceptance'] == true;
            final transferStatus = isBatch && needsAccept
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
            break;
          case 'transfer_paused':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.paused,
              pausedBy: message['pausedBy'] as String?,
              canResume: message['canResume'] as bool? ?? false,
            );
            break;
          case 'transfer_resumed':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'transfer_accepted':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.inProgress,
            );
            break;
          case 'transfer_cancelled':
            _updateTransferStatus(
              message['fileId'] as String?,
              TransferStatus.cancelled,
            );
            break;
          case 'transfer_cancel_ready':
            setState(() {
              isSharingInProgress = false;
            });
            if (_suppressNextConnectionIssueAfterCancellation) {
              Future<void>.delayed(const Duration(seconds: 2), () {
                _suppressNextConnectionIssueAfterCancellation = false;
              });
            }
            break;

          case 'error':
            final isFatal = message['fatal'] == 'true';
            final errorText =
                message['message'] as String? ??
                AppLocalizations.of(context).unknownError;
            if (isFatal) {
              // 致命错误不再弹窗，只按会话结束处理；原因写进日志便于排查。
              debugPrint('[SESSION] fatal error: $errorText');
              _fatalErrorReceived = true;
              _reportSessionIssueAfterCancellationWindow();
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
                          constraints: (Platform.isAndroid || Platform.isIOS)
                              ? BoxConstraints()
                              : BoxConstraints(maxWidth: 500),
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
                        constraints: (Platform.isAndroid || Platform.isIOS)
                            ? BoxConstraints()
                            : BoxConstraints(maxWidth: 500),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child:
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: ValueListenableBuilder(
                                      valueListenable: isDisconnected,
                                      builder: (context, value, child) => Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        spacing: 10,
                                        children: [
                                          // 传输中在状态按键上方提供整批操作。
                                          if (!value && isSharingInProgress)
                                            _buildBatchTransferControls(),
                                          _buildTransferActions(
                                            isConnectionLost: value,
                                          ),
                                        ],
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

  /// 传输中显示的整批操作：全部暂停（全部暂停后变为全部继续）、全部取消。
  Widget _buildBatchTransferControls() {
    return ValueListenableBuilder<List<TransferWidget>>(
      valueListenable: _fileTransferWidgets,
      builder: (context, widgets, child) {
        final l10n = AppLocalizations.of(context);
        final allPaused = _allPaused(widgets);
        return Row(
          spacing: 10,
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _toggleAllPaused,
                icon: Icon(
                  allPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                ),
                label: Text(allPaused ? l10n.resumeAll : l10n.pauseAll),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _cancelAllTransfers,
                icon: const Icon(Icons.close_rounded),
                label: Text(l10n.cancelAll),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 空闲时显示三个发送入口；传输中或连接断开时显示一个不可点击的状态按键。
  ///
  /// 连接断开后按键直接显示结果：打断过未完成的传输时显示“传输被中断”，
  /// 传输都已结束时显示“连接已断开”。
  Widget _buildTransferActions({required bool isConnectionLost}) {
    final l10n = AppLocalizations.of(context);
    if (isConnectionLost || isSharingInProgress) {
      final interrupted =
          isConnectionLost &&
          _sessionIssue == _SessionIssue.transferInterrupted;
      final icon = isConnectionLost
          ? interrupted
              ? Icons.sync_problem_rounded
              : Icons.link_off_rounded
          : Icons.hourglass_top_rounded;
      final title = isConnectionLost
          ? interrupted
              ? l10n.transferInterrupted
              : l10n.connectionLost
          : l10n.transferInProgress;
      return _buildTransferStatusButton(
        icon: icon,
        title: title,
        subtitle: isConnectionLost
            ? l10n.reconnectToSendMore
            : l10n.waitForTransferToFinish,
        disconnected: isConnectionLost,
      );
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
    SocketService.instance.sendFilesSeparately(locations);
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

  /// 多选文件后逐个排队发送；每个文件都是独立的单文件请求。
  Future<void> _pickFilesToSend() async {
    final pickedFiles = await FastFilePicker.pickMultipleFiles();
    if (!mounted || pickedFiles == null || pickedFiles.isEmpty) return;

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
    SocketService.instance.sendFilesSeparately(locations);
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

  /// 选择文件夹并把其中所有文件逐个加入发送队列。
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
        SocketService.instance.sendFilesSeparately([
          for (final document in documents) document.uri,
        ]);
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
      SocketService.instance.sendFilesSeparately(paths);
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
    setState(() {
      isSharingInProgress = false;
      _sessionIssue ??= interrupted
          ? _SessionIssue.transferInterrupted
          : _SessionIssue.connectionLost;
    });
    isDisconnected.value = true;
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
        onAccept: () => SocketService.instance.acceptTransfer(uuid),
        onDecline: () => SocketService.instance.declineTransfer(uuid),
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

  /// 未结束的传输是否全部处于暂停状态。
  bool _allPaused(List<TransferWidget> widgets) {
    final active = widgets.where(
      (widget) =>
          widget.status != TransferStatus.completed &&
          widget.status != TransferStatus.cancelled,
    );
    return active.isNotEmpty &&
        active.every((widget) => widget.status == TransferStatus.paused);
  }

  /// 全部暂停与全部继续的切换，按钮文案由 [_allPaused] 决定。
  void _toggleAllPaused() {
    final widgets = _fileTransferWidgets.value;
    final resume = _allPaused(widgets);
    for (final widget in widgets) {
      if (widget.status == TransferStatus.completed ||
          widget.status == TransferStatus.cancelled) {
        continue;
      }
      if (resume) {
        if (widget.status != TransferStatus.paused) continue;
        SocketService.instance.resumeTransfer(
          widget.uuid,
          isReceiver: widget.isReceived,
        );
      } else {
        if (widget.status == TransferStatus.paused) continue;
        SocketService.instance.pauseTransfer(
          widget.uuid,
          isReceiver: widget.isReceived,
        );
      }
    }
  }

  /// 取消所有尚未结束的传输；发送方向按用户取消处理，避免被当成连接异常。
  void _cancelAllTransfers() {
    // 先丢弃还没开始发送的排队文件，避免取消后它们又一个个发出去。
    SocketService.instance.cancelQueuedSends();
    for (final widget in _fileTransferWidgets.value) {
      if (widget.status == TransferStatus.completed ||
          widget.status == TransferStatus.cancelled) {
        continue;
      }
      _cancelTransfer(widget.uuid, isReceived: widget.isReceived);
    }
  }

  Future<void> _handleDisconnectAfterCancellationWindow() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || _suppressNextConnectionIssueAfterCancellation) {
      if (mounted) {
        isDisconnected.value = true;
      }
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
  Future<void> _reportSessionIssueAfterCancellationWindow() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted ||
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
