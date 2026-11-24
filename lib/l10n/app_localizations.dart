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
  String get appTitle => 'Flashbyte';
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
