import 'dart:async';
import 'dart:io';

import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 后台运行权限门禁。
///
/// Android 需要“电池优化豁免”，iOS 需要“后台 App 刷新”，否则应用转入后台后进程会被
/// 系统冻结，活动连接与文件传输都会中断。未放行时用不可关闭的遮罩弹窗挡住整个界面，
/// 只保留标题与【前往】按钮；放行后遮罩自动消失。
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
  bool? _granted;

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

  // 从系统设置返回时重新检查：放行后遮罩自动消失
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (!_isMobile) {
      if (mounted && _granted != true) {
        setState(() => _granted = true);
      }
      return;
    }

    bool granted;
    try {
      granted =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
    } on MissingPluginException {
      // 原生侧没有实现该通道时不拦截，避免旧安装包被永久挡住
      granted = true;
    } on PlatformException {
      granted = true;
    }

    if (mounted && granted != _granted) {
      setState(() => _granted = granted);
    }
  }

  Future<void> _openSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppInfoSettings');
    } on MissingPluginException {
      // 原生侧未实现，忽略
    } on PlatformException {
      // 系统页面打开失败，忽略
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isMobile || _granted != false) {
      return widget.child;
    }

    // 遮罩层铺满整个应用，点击不会穿透，也没有任何关闭入口
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        const ModalBarrier(color: Color(0x99000000), dismissible: false),
        Center(
          child: _BlockingPermissionCard(onGo: _openSettings),
        ),
      ],
    );
  }
}

/// 不可关闭的权限卡片：只有标题与【前往】按钮
class _BlockingPermissionCard extends StatelessWidget {
  const _BlockingPermissionCard({required this.onGo});

  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = Platform.isIOS
        ? l10n.backgroundRefreshGateTitle
        : l10n.batteryOptimizationGateTitle;

    return Card(
      elevation: 12,
      margin: const EdgeInsets.symmetric(horizontal: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onGo, child: Text(l10n.goToSettings)),
          ],
        ),
      ),
    );
  }
}
