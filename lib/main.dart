import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:flashbyte/widgets/background_permission_gate.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/models/discovered_device.dart';
import 'package:flashbyte/platform/window_state_manager.dart';
import 'package:flashbyte/services/discovery/device_discovery_service.dart';
import 'package:flashbyte/services/platform/android_connection_notification_service.dart';
import 'package:flashbyte/services/sharing/incoming_share_service.dart';
import 'package:flashbyte/app/app_settings.dart';
import 'package:flashbyte/app/controllers/app_appearance_controller.dart';
import 'package:flashbyte/app/controllers/app_locale_controller.dart';
import 'package:flashbyte/app/controllers/app_motion_controller.dart';
import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flashbyte/services/security/tls_identity_service.dart';
import 'package:flashbyte/services/security/trusted_devices_service.dart';
import 'package:flashbyte/features/settings/settings_page.dart';
import 'package:flashbyte/features/transfers/pages/file_selection_page.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:heroine/heroine.dart';
import 'package:material_new_shapes/material_new_shapes.dart';
import 'package:motor/motor.dart';
import 'package:shared_preferences/shared_preferences.dart';

WindowStateManager? _windowStateManager;

@pragma('vm:entry-point')
Future<void> onNotificationActionReceived(ReceivedAction receivedAction) async {
  await AndroidConnectionNotificationService.instance.handleNotificationAction(
    receivedAction,
  );
}

@pragma('vm:entry-point')
Future<void> onNotificationDismissed(ReceivedAction receivedAction) async {
  await AndroidConnectionNotificationService.instance
      .handleNotificationDismissed(
        receivedAction,
      );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 读取语言设置，使通知渠道名称与描述匹配应用语言。
  // AppLocaleController 此时尚未加载，因此直接读取持久化设置。
  final languageCode = await AppSettings.getLanguage();
  final isZh = languageCode == 'zh' ||
      (languageCode == 'system' &&
          Platform.localeName.toLowerCase().startsWith('zh'));

  await AwesomeNotifications().initialize(
    'resource://drawable/ic_notification',
    [
      NotificationChannel(
        channelKey: 'tcp_connection_service',
        channelName: isZh ? 'TCP 连接服务' : 'TCP connection service',
        channelDescription: isZh
            ? '当 Flashbyte 有活动 TCP 连接时显示。'
            : 'Shows when Flashbyte has an active TCP connection.',
        channelShowBadge: false,
        importance: NotificationImportance.Min,
        playSound: false,
        enableVibration: false,
        onlyAlertOnce: true,
      ),
      NotificationChannel(
        channelKey: 'file_transfer_progress',
        channelName: isZh ? '文件传输进度' : 'File transfer progress',
        channelDescription: isZh
            ? '显示活动的 Flashbyte 文件传输进度。'
            : 'Shows active Flashbyte file transfer progress.',
        channelShowBadge: false,
        importance: NotificationImportance.High,
