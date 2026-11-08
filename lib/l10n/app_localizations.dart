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

  String get appTitle => isZh ? '闪传' : 'Flashbyte';
  String get localFileSharing => isZh ? '本地文件分享' : 'Local file sharing';
  String get sendFiles => isZh ? '发送文件' : 'Send files';
  String get receiveFiles => isZh ? '接收文件' : 'Receive files';
  String get chooseFilesToShare => isZh ? '选择要分享的文件' : 'Choose files to share';
  String get waitForSender => isZh ? '等待发送方' : 'Wait for a sender';
  String get settings => isZh ? '设置' : 'Settings';
  String get startTransfer => isZh ? '开始传输' : 'Start a transfer';
  String get chooseFiles => isZh ? '选择文件' : 'Choose files';
  String get shareFilesDescription =>
      isZh ? '与本地网络中的设备分享文件。' : 'Share files with devices on your local network.';

  // 设置页
  String get appearance => isZh ? '外观' : 'Appearance';
  String get darkMode => isZh ? '深色模式' : 'Dark Mode';
  String get darkModeSubtitle => isZh
      ? '使用应用的深色主题代替浅色主题。'
      : "Use the app's dark theme instead of the light theme.";
  String get darkModeAmoledSubtitle =>
      isZh ? 'AMOLED 主题下始终开启。' : 'Always on for the AMOLED theme.';
  String get reduceAnimations => isZh ? '减少动画' : 'Reduce Animations';
  String get reduceAnimationsSubtitle =>
      isZh ? '减少应用中的动态效果。' : 'Reduce motion across the app.';
  String get staticReceiveShape => isZh ? '静态接收图形' : 'Static Receive Shape';
  String get staticReceiveShapeSubtitle => isZh
      ? '仅停止接收页上的大型旋转图形。'
      : 'Stop only the large spinning shape on the receive tab.';
  String get dynamicColors =>
      isZh ? 'Material You 动态取色' : 'Material You Dynamic Colors';
  String get dynamicColorsSubtitle => isZh
      ? '在支持时使用设备壁纸配色方案。'
      : 'Use the device wallpaper color scheme when supported.';
  String get amoled => isZh ? 'AMOLED' : 'AMOLED';
  String get connection => isZh ? '连接' : 'Connection';
  String get tlsEncryption => isZh ? 'TLS 加密' : 'TLS Encryption';
  String get tlsEncryptionSubtitle => isZh
      ? '使用本设备生成的唯一证书加密传输。'
      : 'Encrypt transfers with a unique certificate generated on this device.';
  String get disconnectBeforeTls =>
      isZh ? '更改 TLS 设置前请断开连接。' : 'Disconnect before changing TLS settings.';
  String get port => isZh ? '端口' : 'Port';
  String get portSubtitle =>
      isZh ? '用于托管和连接。' : 'Used for both hosting and connecting.';
  String get disconnectBeforePort =>
      isZh ? '更改连接端口前请断开连接。' : 'Disconnect before changing the connection port.';
  String get downloadFolder => isZh ? '下载文件夹' : 'Download Folder';
  String get downloadFolderSubtitle => isZh
      ? '接收到的文件将保存在此处。'
      : 'Files received on this device will be saved here.';
  String get disconnectBeforeFolder =>
      isZh ? '更改目标文件夹前请断开连接。' : 'Disconnect before changing the destination folder.';
  String get resetFolder => isZh ? '重置文件夹' : 'Reset folder';
  String get trustedDevices => isZh ? '受信任的设备' : 'Trusted devices';
  String get trustedDevicesDescription => isZh
      ? '标记为受信任的发送方在发送文件时会自动接受。'
      : 'Senders marked as trusted are automatically accepted when they send files.';
  String get noTrustedDevices => isZh ? '无受信任设备' : 'No trusted devices';
  String get noTrustedDevicesSubtitle => isZh
      ? '在接收文件界面勾选“始终接受来自…的文件”以信任发送方。'
      : 'Check “Always accept files from…” on the incoming files screen to trust a sender.';
  String get removeTrustedDevice => isZh ? '从受信任设备中移除' : 'Remove from trusted devices';
  String get language => isZh ? '语言' : 'Language';
  String get languageSystem => isZh ? '跟随系统' : 'Follow system';
  String get languageChinese => isZh ? '简体中文' : 'Simplified Chinese';
  String get languageEnglish => isZh ? '英文' : 'English';
  String get tlsDialogTitle => isZh ? 'TLS 加密' : 'TLS Encryption';
  String get tlsDialogContent => isZh
      ? '禁用 TLS 时，发送和接收设备必须具有相同设置。\n\n请确保另一台设备也关闭了 TLS，否则连接将失败。'
      : 'When TLS is disabled, both the sending and receiving device must have the same setting.\n\n'
          'Make sure the other device also has TLS turned OFF, otherwise the connection will fail.';
  String get dontShowAgain => isZh ? '不再显示' : "Don't show this again";
  String get continueText => isZh ? '继续' : 'Continue';
  String get portRangeError =>
      isZh ? '端口必须在 1 到 65535 之间。' : 'Port must be between 1 and 65535.';
  String get folderUnavailable =>
      isZh ? '此设备无法使用该文件夹。' : 'That folder cannot be used on this device.';
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
