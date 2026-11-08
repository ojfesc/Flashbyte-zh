import 'dart:async';
import 'dart:io';

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
  /// 显示器断开或分辨率变化时回退到居中，避免窗口出现在屏幕外。
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
      for (final display in displays) {
        final displayRect = Rect.fromLTWH(
          display.visiblePosition.dx,
          display.visiblePosition.dy,
          display.visibleSize.width,
          display.visibleSize.height,
        );
        if (displayRect.overlaps(windowRect)) return true;
      }
    } catch (_) {
      // 某些 Wayland 环境无法读取显示器信息，回退到居中。
    }
    return false;
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
    if (_initialized) {
      windowManager.removeListener(this);
    }
  }
}
