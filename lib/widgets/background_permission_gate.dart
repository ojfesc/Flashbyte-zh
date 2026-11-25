import 'dart:async';
import 'dart:io';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 启动权限门禁。
///
/// 应用依赖两项系统权限：通知权限（常驻通知展示传输进度与连接状态）和电池优化豁免
/// （iOS 为后台 App 刷新，缺少时应用转入后台会被系统挂起）。未满足时用不可穿透的
/// 遮罩挡住界面，并按“通知权限 → 电池优化”的顺序只显示第一个缺失项的引导框；
/// 用户处理完一项回到应用后，再检查并提示下一项。
class BackgroundPermissionGate extends StatefulWidget {
  const BackgroundPermissionGate({required this.child, super.key});

  final Widget child;

  @override
  State<BackgroundPermissionGate> createState() =>
      _BackgroundPermissionGateState();
}

class _BackgroundPermissionGateState extends State<BackgroundPermissionGate>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(
    'flashbyte/battery_optimization',
  );

  // true 已放行；false 未放行；null 尚未检查完成
  bool? _batteryExempt;
  bool? _notificationsAllowed;

  // 只有移动端需要申请，桌面端没有对应开关
  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 从系统设置返回时重新检查：放行后对应的引导框自动消失
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 生命周期写进日志，用于核对传输中断是否发生在应用切到后台之后。
    debugPrint('[SESSION] app lifecycle ${state.name}');
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (!_isMobile) {
      if (mounted && _batteryExempt != true) {
        setState(() {
          _batteryExempt = true;
          _notificationsAllowed = true;
        });
      }
      return;
    }

    final batteryExempt = await _readBatteryExempt();
    final notificationsAllowed = await _readNotificationsAllowed();
    if (!mounted) return;
    if (batteryExempt != _batteryExempt ||
        notificationsAllowed != _notificationsAllowed) {
      setState(() {
        _batteryExempt = batteryExempt;
        _notificationsAllowed = notificationsAllowed;
      });
    }
  }

  Future<bool> _readBatteryExempt() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } on MissingPluginException {
      // 原生侧没有实现该通道时不拦截，避免旧安装包被永久挡住
      return true;
    } on PlatformException {
      return true;
    }
  }

  Future<bool> _readNotificationsAllowed() async {
    try {
      return await AwesomeNotifications().isNotificationAllowed();
    } catch (_) {
      // 查询失败时不拦截，避免把用户挡在门外
      return true;
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await AwesomeNotifications().showNotificationConfigPage();
    } catch (_) {
      // 系统页面打开失败时忽略，回到应用后会重新检查
    }
  }

  Future<void> _openBatterySettings() async {
    try {
      await _channel.invokeMethod<void>('openAppInfoSettings');
    } on MissingPluginException {
      // 原生侧未实现，忽略
    } on PlatformException {
      // 系统页面打开失败，忽略
    }
  }

  bool get _needsNotificationPermission => _notificationsAllowed == false;

  bool get _needsBatteryExemption => _batteryExempt == false;

  @override
  Widget build(BuildContext context) {
    if (!_isMobile ||
        (!_needsNotificationPermission && !_needsBatteryExemption)) {
      return widget.child;
    }

    // 遮罩铺满整个应用，点击不会穿透；同一时刻只显示一个引导框
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        const ModalBarrier(color: Color(0x99000000), dismissible: false),
        Center(
          child: _needsNotificationPermission
              ? _NotificationPermissionDialog(onGo: _openNotificationSettings)
              : _BatteryPermissionDialog(onGo: _openBatterySettings),
        ),
      ],
    );
  }
}

/// 通知权限引导框：说明用途后跳系统通知设置，不提供跳过。
class _NotificationPermissionDialog extends StatelessWidget {
  const _NotificationPermissionDialog({required this.onGo});

  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.notificationPermissionTitle),
      content: Text(l10n.notificationPermissionMessage),
      actions: [
        FilledButton(onPressed: onGo, child: Text(l10n.goToEnable)),
      ],
    );
  }
}

/// 电池优化/后台刷新引导框：属于应用后台运行的前提，不提供跳过。
class _BatteryPermissionDialog extends StatelessWidget {
  const _BatteryPermissionDialog({required this.onGo});

  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isIos = Platform.isIOS;
    return AlertDialog(
      title: Text(
        isIos
            ? l10n.backgroundRefreshGateTitle
            : l10n.batteryOptimizationGateTitle,
      ),
      content: Text(
        isIos
            ? l10n.backgroundRefreshGateMessage
            : l10n.batteryOptimizationGateMessage,
      ),
      actions: [
        FilledButton(onPressed: onGo, child: Text(l10n.goToEnable)),
      ],
    );
  }
}
