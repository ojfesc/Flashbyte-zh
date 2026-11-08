import 'package:flutter/material.dart';

/// 应用本地化字符串，支持英文和简体中文。
class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [Locale('en'), Locale('zh')];

  bool get isZh => locale.languageCode == 'zh';

  // 通用
  String get appTitle => isZh ? '闪传' : 'Flashbyte';
  String get settings => isZh ? '设置' : 'Settings';
  String get language => isZh ? '语言' : 'Language';
  String get languageSystem => isZh ? '跟随系统' : 'Follow system';
  String get languageChinese => isZh ? '简体中文' : 'Simplified Chinese';
  String get languageEnglish => isZh ? '英文' : 'English';
  String get dismiss => isZh ? '关闭' : 'Dismiss';
  String get cancel => isZh ? '取消' : 'Cancel';
  String get backToFileSelection =>
      isZh ? '返回文件选择' : 'Back to file selection';
  String get unknownDevice => isZh ? '未知设备' : 'Unknown device';

  // 主页
  String get localFileSharing => isZh ? '本地文件分享' : 'Local file sharing';
  String get sendFiles => isZh ? '发送文件' : 'Send files';
  String get receiveFiles => isZh ? '接收文件' : 'Receive files';
  String get chooseFilesToShare => isZh ? '选择要分享的文件' : 'Choose files to share';
  String get waitForSender => isZh ? '等待发送方' : 'Wait for a sender';
  String get startTransfer => isZh ? '开始传输' : 'Start a transfer';
  String get chooseFiles => isZh ? '选择文件' : 'Choose files';
  String get shareFilesDescription =>
      isZh ? '与本地网络中的设备分享文件。' : 'Share files with devices on your local network.';

  // 电池优化提示
  String get allowBackgroundTransfers =>
      isZh ? '允许后台传输' : 'Allow background transfers';
  String get batteryOptimizationMessage => isZh
      ? '请关闭 Flashbyte 的电池优化，以便活动连接和文件传输在后台继续运行。'
      : 'Disable battery optimization for Flashbyte so active connections and file transfers can keep running in the background.';
  String get doNotShowAgain => isZh ? '不再显示' : 'Do not show again';
  String get notNow => isZh ? '暂时不要' : 'Not now';
  String get disable => isZh ? '关闭' : 'Disable';

  // 设置页 - 外观
  String get appearance => isZh ? '外观' : 'Appearance';
  String get darkMode => isZh ? '深色模式' : 'Dark Mode';
  String get darkModeSubtitle =>
      isZh ? '使用应用的深色主题代替浅色主题。' : "Use the app's dark theme instead of the light theme.";
  String get darkModeAmoledSubtitle =>
      isZh ? 'AMOLED 主题下始终开启。' : 'Always on for the AMOLED theme.';
  String get reduceAnimations => isZh ? '减少动画' : 'Reduce Animations';
  String get reduceAnimationsSubtitle =>
      isZh ? '减少应用中的动态效果。' : 'Reduce motion across the app.';
  String get staticReceiveShape => isZh ? '静态接收图形' : 'Static Receive Shape';
  String get staticReceiveShapeSubtitle =>
      isZh ? '仅停止接收页上的大型旋转图形。' : 'Stop only the large spinning shape on the receive tab.';
  String get dynamicColors =>
      isZh ? 'Material You 动态取色' : 'Material You Dynamic Colors';
  String get dynamicColorsSubtitle => isZh
      ? '在支持时使用设备壁纸配色方案。'
      : 'Use the device wallpaper color scheme when supported.';
  String get amoled => 'AMOLED';

  // 设置页 - 连接
  String get connection => isZh ? '连接' : 'Connection';
  String get tlsEncryption => isZh ? 'TLS 加密' : 'TLS Encryption';
  String get tlsEncryptionSubtitle => isZh
      ? '使用本设备生成的唯一证书加密传输。'
      : 'Encrypt transfers with a unique certificate generated on this device.';
  String get disconnectBeforeTls => isZh
      ? '更改 TLS 设置前请断开连接。'
      : 'Disconnect before changing TLS settings.';
  String get port => isZh ? '端口' : 'Port';
  String get portSubtitle => isZh ? '用于托管和连接。' : 'Used for both hosting and connecting.';
  String get disconnectBeforePort => isZh
      ? '更改连接端口前请断开连接。'
      : 'Disconnect before changing the connection port.';
  String get downloadFolder => isZh ? '下载文件夹' : 'Download Folder';
  String get downloadFolderSubtitle => isZh
      ? '接收到的文件将保存在此处。'
      : 'Files received on this device will be saved here.';
  String get disconnectBeforeFolder => isZh
      ? '更改目标文件夹前请断开连接。'
      : 'Disconnect before changing the destination folder.';
  String get resetFolder => isZh ? '重置文件夹' : 'Reset folder';
  String get trustedDevices => isZh ? '受信任的设备' : 'Trusted devices';
  String get trustedDevicesDescription => isZh
      ? '标记为受信任的发送方在发送文件时会自动接受。'
      : 'Senders marked as trusted are automatically accepted when they send files.';
  String get noTrustedDevices => isZh ? '无受信任设备' : 'No trusted devices';
  String get noTrustedDevicesSubtitle => isZh
      ? '在接收文件界面勾选“始终接受来自…的文件”以信任发送方。'
      : 'Check “Always accept files from…” on the incoming files screen to trust a sender.';
  String get removeTrustedDevice =>
      isZh ? '从受信任设备中移除' : 'Remove from trusted devices';

  // 设置页 - 对话框与提示
  String get tlsDialogTitle => isZh ? 'TLS 加密' : 'TLS Encryption';
  String get tlsDialogContent => isZh
      ? '禁用 TLS 时，发送和接收设备必须具有相同设置。\n\n请确保另一台设备也关闭了 TLS，否则连接将失败。'
      : 'When TLS is disabled, both the sending and receiving device must have the same setting.\n\n'
          'Make sure the other device also has TLS turned OFF, otherwise the connection will fail.';
  String get continueText => isZh ? '继续' : 'Continue';
  String get portRangeError =>
      isZh ? '端口必须在 1 到 65535 之间。' : 'Port must be between 1 and 65535.';
  String get folderUnavailable =>
      isZh ? '此设备无法使用该文件夹。' : 'That folder cannot be used on this device.';

  // 文件选择页
  String get flashbyte => isZh ? '闪传' : 'Flashbyte';
  String get send => isZh ? '发送' : 'Send';
  String get receive => isZh ? '接收' : 'Receive';
  String get fileTransfer => isZh ? '文件传输' : 'File transfer';
  String get sendReceiveOnLocalNetwork => isZh
      ? '在同一工作空间中发送和接收本地网络文件。'
      : 'Send and receive on your local network from one workspace.';
  String get sendPanelTitle => isZh ? '发送' : 'Send';
  String get sendPanelSubtitle =>
      isZh ? '选择文件并连接到接收方' : 'Choose files and connect to a receiver';
  String get receivePanelTitle => isZh ? '接收' : 'Receive';
  String get receivePanelSubtitle =>
      isZh ? '保持此页面打开以保持可被发现' : 'Keep this page open to stay discoverable';
  String get networkChecking => isZh ? '正在检查网络' : 'Checking network';
  String get hotspotActive => isZh ? '热点已开启' : 'Hotspot active';
  String get connectedToWifi => isZh ? '已连接至 Wi-Fi' : 'Connected to Wi-Fi';
  String get usingMobileData => isZh ? '正在使用移动数据' : 'Using mobile data';
  String get connectedByEthernet => isZh ? '已通过以太网连接' : 'Connected by Ethernet';
  String get connectedThroughVpn => isZh ? '已通过 VPN 连接' : 'Connected through VPN';
  String get noNetworkConnection => isZh ? '无网络连接' : 'No network connection';
  String get serverRunning => isZh ? '服务器运行中' : 'Server running';
  String get secureServerRunning => isZh ? '安全服务器运行中' : 'Secure server running';
  String get serverStopped => isZh ? '服务器已停止' : 'Server stopped';
  String get pickFiles => isZh ? '选择文件' : 'Pick files';
  String get changeFiles => isZh ? '更换文件' : 'Change files';
  String get picking => isZh ? '正在选择…' : 'Picking...';
  String get folder => isZh ? '文件夹' : 'Folder';
  String get noFilesSelected => isZh ? '未选择文件' : 'No files selected';
  String nFilesSelected(int count) {
    if (count == 1) return isZh ? '已选择 1 个文件' : '1 file selected';
    return isZh ? '已选择 $count 个文件' : '$count files selected';
  }

  String get chooseWhatToSend => isZh ? '选择要发送的内容。' : 'Choose what you want to send.';
  String get readyToSend => isZh
      ? '选择接收方后即可发送。'
      : 'Ready to send after you pick a receiver.';
  String get clearSelectedFiles => isZh ? '清除已选文件' : 'Clear selected files';
  String get dropFilesHere => isZh ? '将文件拖放到此处' : 'Drop files here';
  String get releaseToReplaceSelection => isZh
      ? '松开以替换当前选择。'
      : 'Release to replace the current selection.';
  String get nearbyReceivers => isZh ? '附近的接收方' : 'Nearby receivers';
  String get tapDeviceToOffer =>
      isZh ? '点击设备以发送所选文件。' : 'Tap a device to offer the selected files.';
  String get refreshNearbyReceivers =>
      isZh ? '刷新附近接收方' : 'Refresh nearby receivers';
  String get scanningNetwork => isZh ? '正在扫描此网络' : 'Scanning this network';
  String get noReceiversFound => isZh ? '未发现接收方' : 'No receivers found';
  String get receiversAppearHere => isZh
      ? '接收方可被发现时将出现在此处。'
      : 'Receivers will appear here as soon as they are discoverable.';
  String get makeSureOtherDeviceOpen => isZh
      ? '请确保另一台设备打开接收并连接到同一网络。'
      : 'Make sure the other device is open on Receive and connected to this network.';
  String get localReceiverSecure => isZh ? '本地接收方 - 安全' : 'Local receiver - secure';
  String get localReceiver => isZh ? '本地接收方' : 'Local receiver';
  String get visibleAs => isZh ? '可见名称' : 'Visible as';
  String get creatingYourName => isZh ? '正在创建你的名称…' : 'Creating your name...';
  String get resetToDeviceName => isZh ? '重置为设备名称' : 'Reset to device name';
  String get generateNewName => isZh ? '生成新名称' : 'Generate a new name';
  String get sendFilesTitle => isZh ? '发送文件' : 'Send files';
  String get pickFilesThenChoose => isZh
      ? '选择文件，然后选择附近的接收方。'
      : 'Pick files, then choose a nearby receiver.';
  String get receiveFilesTitle => isZh ? '接收文件' : 'Receive files';
  String get stayVisible => isZh
      ? '等待期间请保持可见以被附近设备发现。'
      : 'Stay visible to nearby devices while you wait.';
  String get visibleToNearbyDevices =>
      isZh ? '对附近设备可见' : 'Visible to nearby devices';
  String get startingReceiver => isZh ? '正在启动接收方' : 'Starting receiver';
  String get receiverStopped => isZh ? '接收方已停止' : 'Receiver stopped';
  String get keepFlashbyteOpen => isZh
      ? '请保持 Flashbyte 打开，以便发送方找到此设备。'
      : 'Keep Flashbyte open so senders can find this device.';
  String get ready => isZh ? '就绪' : 'Ready';
  String get offline => isZh ? '离线' : 'Offline';
  String get receiveError => isZh ? '接收错误' : 'Receive Error';
  String failedToStartReceiver(Object error) => isZh
      ? '启动接收方失败：\n$error'
      : 'Failed to start receiver:\n$error';
  String get connectionError => isZh ? '连接错误' : 'Connection Error';
  String couldNotConnectToReceiver(Object error) => isZh
      ? '无法连接到接收方：\n$error'
      : 'Could not connect to receiver:\n$error';
  String get tlsSettingsDoNotMatch =>
      isZh ? 'TLS 设置不匹配' : 'TLS Settings Do Not Match';
  String get tlsMismatchLocalOn => isZh
      ? '此设备已启用 TLS，但所选设备已禁用 TLS。\n\n请关闭此设备的 TLS，或在另一台设备上启用 TLS，然后重试。'
      : 'This device has TLS enabled, but the selected device has TLS disabled.\n\nDisable TLS on this device, or enable TLS on the other device, then try again.';
  String get tlsMismatchLocalOff => isZh
      ? '此设备已禁用 TLS，但所选设备已启用 TLS。\n\n请启用此设备的 TLS，或在另一台设备上禁用 TLS，然后重试。'
      : 'This device has TLS disabled, but the selected device has TLS enabled.\n\nEnable TLS on this device, or disable TLS on the other device, then try again.';
  String get selectAtLeastOneFile => isZh ? '请先选择至少一个文件' : 'Select at least one file first';
  String get unknownError => isZh ? '未知错误' : 'Unknown error';
  String get cannotReadFolder =>
      isZh ? '此设备无法读取该文件夹。' : 'Cannot read this folder on this device.';
  String get folderNotFound => isZh ? '文件夹不存在。' : 'Folder not found.';
  String get noFilesInSelectedFolder =>
      isZh ? '所选文件夹中没有文件。' : 'No files found in the selected folder.';
  String get dropFilesOnly => isZh
      ? '在此处放置文件。暂不支持文件夹。'
      : 'Drop files here. Folders are not supported yet.';
  String sharedFilesAdded(int count) => count == 1
      ? (isZh ? '已添加 1 个共享文件' : '1 shared file added')
      : (isZh ? '已添加 $count 个共享文件' : '$count shared files added');

  // 接收请求页
  String get incomingFiles => isZh ? '接收文件' : 'Incoming files';
  String get devices => isZh ? '设备' : 'Devices';
  String get sender => isZh ? '发送方' : 'Sender';
  String get thisDevice => isZh ? '此设备' : 'This device';
  String get requestedFile => isZh ? '请求的文件' : 'Requested file';
  String get requestedFiles => isZh ? '请求的文件' : 'Requested files';
  String get approveIncomingFile => isZh ? '批准接收文件' : 'Approve incoming file';
  String get approveIncomingFiles => isZh ? '批准接收文件' : 'Approve incoming files';
  String get reviewSenderAndFile => isZh
      ? '保存前请查看发送方和文件。'
      : 'Review the sender and file before saving it here.';
  String reviewSenderAndNFiles(int count) => isZh
      ? '保存前请查看发送方和 $count 个文件。'
      : 'Review the sender and $count files before saving them here.';
  String alwaysAcceptFilesFrom(String name) =>
      isZh ? '始终接受来自 $name 的文件' : 'Always accept files from $name';
  String get skipApproval => isZh
      ? '跳过此设备的批准界面。'
      : 'Skip this approval screen for this device.';
  String get acceptAndReceive => isZh ? '接受并接收' : 'Accept and receive';
  String get decline => isZh ? '拒绝' : 'Decline';
  String get declineFiles => isZh ? '拒绝文件' : 'Decline files';
  String get senderCancelledTransfer =>
      isZh ? '发送方已取消传输' : 'Sender cancelled the transfer';
  String get filesDeclined => isZh ? '已拒绝文件' : 'Files declined';
  String get connectionEnded => isZh ? '连接已结束' : 'Connection ended';
  String get senderCancelledMessage => isZh
      ? '发送方不再想发送这些文件。未下载任何文件。'
      : 'The sender no longer wants to send these files. Nothing was downloaded.';
  String get filesDeclinedMessage => isZh
      ? '这些文件未被接受，未下载任何文件。'
      : 'These files were not accepted and nothing was downloaded.';
  String get connectionEndedMessage => isZh
      ? '做出决定之前连接已断开。'
      : 'The connection ended before a decision was made.';
  String get desktopOrLaptop => isZh ? '桌面或笔记本电脑' : 'Desktop or laptop';
  String get phone => isZh ? '手机' : 'Phone';
  String get secureRequest => isZh ? '安全请求' : 'Secure request';
  String get unencryptedRequest => isZh ? '未加密请求' : 'Unencrypted request';
  String get tlsEnabled => isZh ? '已启用 TLS' : 'TLS enabled';
  String get unencrypted => isZh ? '未加密' : 'Unencrypted';
  String portLabel(int port) => isZh ? '端口 $port' : 'Port $port';
  String get addressPending => isZh ? '地址待定' : 'Address pending';
  String get localReceiverLabel => isZh ? '本地接收方' : 'Local receiver';
  String get localSenderLabel => isZh ? '本地发送方' : 'Local sender';

  // 发送请求页
  String get sendingFiles => isZh ? '正在发送文件' : 'Sending files';
  String get waitingForApproval => isZh ? '等待接收方批准' : 'Waiting for approval';
  String get receiverNeedsToAccept => isZh
      ? '发送开始前接收方需要先接受此请求。'
      : 'The receiver needs to accept this request before sending begins.';
  String get receiver => isZh ? '接收方' : 'Receiver';
  String nFilesSelectedCount(int count) =>
      isZh ? '已选择 $count 个文件' : '$count ${count == 1 ? 'file' : 'files'} selected';
  String get cancelTransfer => isZh ? '取消传输' : 'Cancel transfer';
  String get receiverDeclinedFiles =>
      isZh ? '接收方拒绝了文件' : 'Receiver declined the files';
  String get receiverDeclinedMessage => isZh
      ? '接收方选择不接受这些文件。未发送任何文件。'
      : 'The receiver chose not to accept these files. Nothing was sent.';
  String get connectionEndedBeforeResponse => isZh
      ? '接收方响应前连接已断开。未发送任何文件。'
      : 'The connection ended before the receiver responded. No files were sent.';
  String get cancelTransferTooltip => isZh ? '取消传输' : 'Cancel transfer';

  // 聊天/传输页
  String get share => isZh ? '分享' : 'Share';
  String get noFilesSentYet => isZh ? '尚未发送文件。' : 'No files sent yet.';
  String connectedTo(String name) => isZh ? '已连接到 $name' : 'Connected to $name';
  String get connected => isZh ? '已连接' : 'Connected';
  String get disconnected => isZh ? '已断开' : 'Disconnected';
  String get identifyingConnectedDevice =>
      isZh ? '正在识别已连接的设备…' : 'Identifying connected device...';
  String get connectedDevice => isZh ? '已连接设备' : 'Connected device';
  String get sessionEndedMessage => isZh
      ? '此会话已结束。请返回重新连接以继续发送文件。'
      : 'This session ended. Go back to reconnect before sending more files.';
  String get ipAddress => isZh ? 'IP 地址' : 'IP address';
  String get device => isZh ? '设备' : 'Device';
  String get security => isZh ? '安全' : 'Security';
  String get phoneOrTablet => isZh ? '手机或平板' : 'Phone or tablet';
  String get unknownValue => isZh ? '未知' : 'Unknown';
  String get connectionLost => isZh ? '连接已断开' : 'Connection lost';
  String get pickFile => isZh ? '选择文件' : 'Pick File';
  String get reconnectToSendMore =>
      isZh ? '重新连接以继续发送' : 'Reconnect to send more files';
  String get transferInProgress => isZh ? '传输进行中' : 'Transfer in progress';
  String get waitForTransferToFinish =>
      isZh ? '请等待此传输完成' : 'Wait for this transfer to finish';
  String get chooseAnotherFile =>
      isZh ? '选择另一个要发送的文件' : 'Choose another file to send';
  String get couldNotReadSelectedFile =>
      isZh ? '无法读取所选文件' : 'Could not read selected file';
  String get connectionLostDialog =>
      isZh ? '连接已断开' : 'Connection Lost';
  String get connectionLostDuringTransfer => isZh
      ? '连接已断开。另一台设备在传输过程中断开连接。'
      : 'Connection lost. The other device disconnected during the transfer.';
  String get disconnectedSnackbar => isZh ? '已断开' : 'Disconnected';
  String get couldNotSendSharedFiles => isZh
      ? '连接已断开——无法发送共享文件'
      : "Connection lost — couldn't send shared files";
  String sendingSharedFileTo(String name) =>
      isZh ? '正在向 $name 发送共享文件' : 'Sending shared file to $name';
  String sendingNSharedFilesTo(int count, String name) => isZh
      ? '正在向 $name 发送 $count 个共享文件'
      : 'Sending $count shared files to $name';
  String get peer => isZh ? '对方' : 'peer';

  // 传输组件
  String get statusRequest => isZh ? '请求' : 'request';
  String get statusWaiting => isZh ? '等待中' : 'waiting';
  String get statusCancelled => isZh ? '已取消' : 'cancelled';
  String get statusPaused => isZh ? '已暂停' : 'paused';
  String get statusReceived => isZh ? '已接收' : 'received';
  String get statusSent => isZh ? '已发送' : 'sent';
  String get statusReceiving => isZh ? '接收中' : 'receiving';
  String get statusSending => isZh ? '发送中' : 'sending';
  String get pause => isZh ? '暂停' : 'Pause';
  String get continueAction => isZh ? '继续' : 'Continue';
  String get accept => isZh ? '接受' : 'Accept';
  String get waitingForReceiverToAccept =>
      isZh ? '等待接收方接受' : 'Waiting for receiver to accept';
  String fileStatusLine({
    required String size,
    required String ext,
    required String status,
  }) => '$size • $ext • $status';
  String fileProgressLine({
    required String size,
    required String ext,
    required int percent,
  }) => '$size • $ext • $percent%';

  // 文件预览
  String get openFile => isZh ? '打开文件' : 'Open file';
  String get fileMayHaveBeenMovedOrDeleted =>
      isZh ? '文件可能已被移动或删除。' : 'File may have been moved or deleted.';
  String get permissionDenied => isZh ? '权限被拒绝。' : 'Permission denied.';
  String get noAppToOpenThisFile =>
      isZh ? '没有可打开此文件的应用' : 'No app available to open this file';
  String get couldNotOpenFolder =>
      isZh ? '无法打开该文件夹' : "Couldn't open that folder";
  String get transferInProgressStatus =>
      isZh ? '传输进行中' : 'Transfer in progress';
  String get transferCancelledStatus =>
      isZh ? '传输已取消' : 'Transfer cancelled';

  // 网络相关
  String get connectionSetupInterrupted =>
      isZh ? '连接设置被中断。请重试。' : 'Connection setup was interrupted. Try again.';
  String get otherDeviceDisconnected => isZh
      ? '传输完成前另一台设备已断开连接。'
      : 'The other device disconnected before the transfer finished.';
  String get couldNotReachReceiver => isZh
      ? '无法连接接收方。请检查 IP 地址、端口、Wi-Fi 以及接收方是否就绪。'
      : 'Could not reach the receiver. Check the IP address, port, Wi-Fi, and that the receiver is ready.';
  String get invalidIpAddress => isZh ? 'IP 地址格式不正确。' : 'That IP address does not look valid.';
  String get tlsSettingsMismatch => isZh
      ? 'TLS 设置不匹配。请确保两台设备同时启用或禁用 TLS，然后重试。'
      : 'The TLS settings do not match. Make sure TLS is enabled or disabled on both devices, then try again.';
  String get tlsCertificateLoadFailed => isZh
      ? '无法加载 TLS 证书。请检查 TLS 证书设置后重试。'
      : 'The TLS certificate could not be loaded. Check the TLS certificate settings and try again.';
  String get connectionNotActive => isZh
      ? '连接已断开。请重新连接后重试。'
      : 'The connection is not active anymore. Reconnect and try again.';
  String get selectedFileCouldNotBeRead => isZh
      ? '无法读取所选文件。它可能已被移动或删除。'
      : 'The selected file could not be read. It may have been moved or deleted.';
  String get receivedFileCouldNotBeSaved => isZh
      ? '无法保存接收到的文件。请更换文件夹后重试。'
      : 'The received file could not be saved. Choose a different folder and try again.';
  String get permissionDeniedGeneric => isZh
      ? '权限被拒绝。请检查文件或文件夹权限后重试。'
      : 'Permission was denied. Check file or folder permissions and try again.';
  String get somethingWentWrong => isZh ? '出了点问题。' : 'Something went wrong.';

  /// 将 [UserFacingError.from] 产生的英文消息映射为当前语言。
  /// 未匹配的中文或未知英文原样返回。
  String localizeError(String englishMessage) {
    if (!isZh) return englishMessage;
    final l = englishMessage.toLowerCase();
    if (l.contains('connection setup was interrupted')) {
      return connectionSetupInterrupted;
    }
    if (l.contains('disconnected before the transfer finished') ||
        l.contains('disconnected unexpectedly')) {
      return otherDeviceDisconnected;
    }
    if (l.contains('could not reach the receiver')) {
      return couldNotReachReceiver;
    }
    if (l.contains('does not look valid')) {
      return invalidIpAddress;
    }
    if (l.contains('tls settings do not match') ||
        l.contains('tls enabled') ||
        l.contains('tls disabled')) {
      return tlsSettingsMismatch;
    }
    if (l.contains('tls certificate could not be loaded')) {
      return tlsCertificateLoadFailed;
    }
    if (l.contains('connection is not active')) {
      return connectionNotActive;
    }
    if (l.contains('selected file could not be read')) {
      return selectedFileCouldNotBeRead;
    }
    if (l.contains('received file could not be saved')) {
      return receivedFileCouldNotBeSaved;
    }
    if (l.contains('permission was denied')) {
      return permissionDeniedGeneric;
    }
    if (l.contains('something went wrong')) {
      return somethingWentWrong;
    }
    return englishMessage;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales
        .any((supported) => supported.languageCode == locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
