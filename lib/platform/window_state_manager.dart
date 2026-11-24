import 'dart:async';
import 'dart:io';

import 'package:flashbyte/services/transfer/socket_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 管理桌面端窗口的位置与尺寸持久化。
///
/// 初始化时从 [SharedPreferences] 恢复上次保存的几何信息，窗口保持隐藏；
/// Flutter 首帧渲染完成后由 [showWithFadeIn] 显示窗口并执行淡入，
/// 避免用户看到窗口从默认位置跳变或出现空白窗口。
class WindowStateManager with WindowListener {
  WindowStateManager({
    this.defaultSize = const Size(1280, 720),
    this.minimumSize = const Size(600, 700),
  });

  final Size defaultSize;
  final Size minimumSize;

  static const _keyX = 'window_x';
  static const _keyY = 'window_y';
  static const _keyWidth = 'window_width';
  static const _keyHeight = 'window_height';
  static const _keyMaximized = 'window_maximized';

  SharedPreferences? _prefs;
  Timer? _saveDebounce;
  StreamSubscription<Map<String, dynamic>>? _incomingOfferSubscription;
  bool _initialized = false;

  /// 当前平台是否支持窗口位置持久化。
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 初始化窗口管理器并恢复上次保存的位置与尺寸。
  /// 调用后窗口仍保持隐藏，等待 [showWithFadeIn] 显示。
  Future<void> init() async {
    if (!isDesktop || _initialized) return;

    _prefs = await SharedPreferences.getInstance();
    await windowManager.ensureInitialized();

    final options = WindowOptions(
      size: defaultSize,
      minimumSize: minimumSize,
      titleBarStyle: TitleBarStyle.normal,
      skipTaskbar: false,
    );

    // 回调在窗口可显示之前执行，此时恢复坐标不会产生可见跳变。
    await windowManager.waitUntilReadyToShow(options, () async {
      await _restore();
      windowManager.addListener(this);
      _initialized = true;
    });

    // 传输服务收到对端发起的文件请求时会发布 start 消息，
    // 窗口在最小化或后台时由该监听恢复到最前。
    _incomingOfferSubscription = SocketService.instance.messageStream.listen(
      _handleIncomingOffer,
    );
  }

  /// 收到对端主动发起的文件传输时激活窗口，让接收确认界面立即可见。
  void _handleIncomingOffer(Map<String, dynamic> message) {
    final status = message['status'] ?? message['command'];
    if (status != 'start' || message['pendingAcceptance'] != true) {
      return;
    }
    unawaited(_activate());
  }

  /// 在 Flutter 首帧渲染完成后调用，显示窗口并执行淡入。
  Future<void> showWithFadeIn() async {
    if (!isDesktop) return;

    final supportsOpacity = Platform.isWindows || Platform.isMacOS;
    if (supportsOpacity) {
      try {
        await windowManager.setOpacity(0);
      } catch (_) {}
    }

    await windowManager.show();
    await windowManager.focus();

    if (supportsOpacity) {
      // 约 160ms 的线性淡入，避免窗口内容突然出现。
      for (var step = 1; step <= 10; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        try {
          await windowManager.setOpacity(step / 10);
        } catch (_) {}
      }
      try {
        await windowManager.setOpacity(1);
      } catch (_) {}
    }
  }

  /// 恢复窗口层级并激活窗口。
  Future<void> _activate() async {
    if (!isDesktop || !_initialized) return;

    var raised = false;
    try {
      final minimized = await windowManager.isMinimized();
      // isFocused 仅 Windows/macOS 支持，其他桌面平台按未聚焦处理。
      final canCheckFocus = Platform.isWindows || Platform.isMacOS;
      if (!minimized && canCheckFocus && await windowManager.isFocused()) {
        return;
      }
      if (minimized) {
        await windowManager.restore();
      }
      await windowManager.show();
      // 临时置顶再取消置顶，保证窗口没有前台焦点时也能回到最上层。
      await windowManager.setAlwaysOnTop(true);
      raised = true;
      await windowManager.focus();
    } catch (_) {
      // 窗口正在关闭或当前平台不支持相关操作时忽略。
    } finally {
      if (raised) {
        try {
          await windowManager.setAlwaysOnTop(false);
        } catch (_) {
          // 窗口已关闭时忽略。
        }
      }
    }
  }

  Future<void> _restore() async {
    final prefs = _prefs;
    if (prefs == null) return;

    if (prefs.getBool(_keyMaximized) ?? false) {
      await windowManager.maximize();
      return;
    }

    final width = prefs.getDouble(_keyWidth) ?? defaultSize.width;
    final height = prefs.getDouble(_keyHeight) ?? defaultSize.height;
    await windowManager.setSize(Size(width, height));

    final x = prefs.getDouble(_keyX);
    final y = prefs.getDouble(_keyY);

    if (x != null && y != null && await _isOnScreen(x, y, width, height)) {
      await windowManager.setPosition(Offset(x, y));
    } else {
      await windowManager.center();
    }
  }

  /// 检查保存的位置是否仍落在某块显示器的可见区域内。
  ///
  /// `screen_retriever` 的 `Display` 只暴露 `size`（非空）、
  /// `visiblePosition`（可空）与 `visibleSize`（可空）。
  /// `visiblePosition` 缺失时无法可靠推断该显示器在工作区中的偏移，
  /// 因此跳过；若所有显示器都缺 `visiblePosition`（典型 Wayland），
  /// 则无法判断位置是否越界，保留上次位置比强制居中更符合预期。
  Future<bool> _isOnScreen(
    double x,
    double y,
    double width,
    double height,
  ) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) return false;

      final windowRect = Rect.fromLTWH(x, y, width, height);
      var hasUsableGeometry = false;
      for (final display in displays) {
        final position = display.visiblePosition;
        if (position == null) continue;

        hasUsableGeometry = true;
        final size = display.visibleSize ?? display.size;
        final displayRect = Rect.fromLTWH(
          position.dx,
          position.dy,
          size.width,
          size.height,
        );
        if (displayRect.overlaps(windowRect)) return true;
      }

      // 有可用几何信息但全部不重叠，说明窗口位置已越界，回退居中。
      // 所有显示器都缺几何信息时返回 true，保留上次位置。
      return !hasUsableGeometry;
    } catch (_) {
      // 某些 Wayland 环境无法读取显示器信息，回退到居中更安全。
      return false;
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final prefs = _prefs;
    if (prefs == null) return;

    try {
      final maximized = await windowManager.isMaximized();
      await prefs.setBool(_keyMaximized, maximized);
      if (maximized) return;

      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();
      await prefs.setDouble(_keyX, position.dx);
      await prefs.setDouble(_keyY, position.dy);
      await prefs.setDouble(_keyWidth, size.width);
      await prefs.setDouble(_keyHeight, size.height);
    } catch (_) {
      // 窗口关闭过程中读取几何信息可能失败，忽略即可。
    }
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowClose() {
    unawaited(_save());
  }

  void dispose() {
    _saveDebounce?.cancel();
    _incomingOfferSubscription?.cancel();
    if (_initialized) {
      windowManager.removeListener(this);
    }
  }
}
