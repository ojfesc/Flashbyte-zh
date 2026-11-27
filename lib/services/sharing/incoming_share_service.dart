import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/models/shared_files.dart';
import 'package:flashbyte/services/platform/android_document_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 接收其它应用通过系统分享交给 Flashbyte 的内容。
///
/// Android 由原生意图直接回传 content:// URI；iOS 由分享扩展写入 App Group，
/// 主应用再通过通道取走。每次事件只描述“这一次分享”，由界面替换当前选择。
class IncomingShareService with WidgetsBindingObserver {
  IncomingShareService._();

  static final IncomingShareService instance = IncomingShareService._();

  static const MethodChannel _iosChannel = MethodChannel(
    'flashbyte/ios_sharing',
  );

  final _controller = StreamController<SharedFiles>.broadcast();
  bool _initialized = false;
  bool _isDrainingIos = false;

  /// 每次分享发出一条事件，里面只包含这一次分享的内容。
  Stream<SharedFiles> get sharedFilesStream => _controller.stream;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    if (!_supported) {
      return;
    }

    // Android 走系统意图直接拿 content:// URI：分享插件会把整个文件复制到缓存，
    // 几 GB 的文件会长时间没有反应，也会把缓存占满。
    if (Platform.isAndroid) {
      AndroidDocumentService.instance.sharedFilesStream.listen(
        _publish,
        onError: (Object _) {},
      );
      try {
        _publish(await AndroidDocumentService.instance.takeInitialSharedFiles());
      } on PlatformException {
        // 原生通道不可用时按“没有分享内容”处理。
      }
      return;
    }

    // iOS：分享扩展把文件写进 App Group 的共享目录；主应用每次回到前台时取一次。
    // 扩展唤起主应用同样会触发 resumed，因此不需要额外的原生回调。
    WidgetsBinding.instance.addObserver(this);
    await _drainIosShares();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_drainIosShares());
    }
  }

  Future<void> _drainIosShares() async {
    if (_isDrainingIos) {
      return;
    }
    _isDrainingIos = true;
    try {
      final raw = await _iosChannel.invokeMethod<List<dynamic>>(
        'takePendingFiles',
      );
      _publish(_toIosShared(raw));
    } on MissingPluginException {
      // 旧安装包没有实现该通道，忽略即可。
    } on PlatformException {
      // 读取共享目录失败：回到前台时会再试一次。
    } finally {
      _isDrainingIos = false;
    }
  }

  SharedFiles _toIosShared(dynamic raw) {
    if (raw is! List) {
      return SharedFiles.empty;
    }
    final files = <FastFilePickerPath>[];
    final clipboardPaths = <String>{};
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final path = item['path'];
      if (path is! String || path.isEmpty) {
        continue;
      }
      final rawName = item['name'];
      final name = rawName is String && rawName.isNotEmpty
          ? rawName
          : path.split('/').last;
      files.add(FastFilePickerPath.fromPath(name, path));
      if (item['clipboard'] == true) {
        clipboardPaths.add(path);
      }
    }
    return SharedFiles(files: files, clipboardPaths: clipboardPaths);
  }

  void _publish(SharedFiles batch) {
    if (batch.isEmpty || _controller.isClosed) {
      return;
    }
    _controller.add(batch);
  }
}
