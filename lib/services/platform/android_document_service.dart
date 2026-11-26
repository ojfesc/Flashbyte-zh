import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flutter/services.dart';

/// Android 上直接用系统文档选择器和分享意图拿 content:// URI。
///
/// 选文件/收分享时不再经过会复制文件内容的插件：几 GB 的文件复制到缓存既会
/// 长时间没有反应，也会把缓存占满。返回的 [FastFilePickerPath] 中 [FastFilePickerPath.name]
/// 是显示名，[FastFilePickerPath.path] 存的是 content:// URI，传输层识别该前缀后
/// 按 SAF 文档流式读取。
class AndroidDocumentService {
  AndroidDocumentService._();

  static final AndroidDocumentService instance = AndroidDocumentService._();

  static const MethodChannel _channel = MethodChannel('flashbyte/documents');
  static const EventChannel _sharedChannel = EventChannel(
    'flashbyte/documents/shared',
  );

  /// 系统文件选择器多选结果；用户取消时返回空列表。
  Future<List<FastFilePickerPath>> pickDocuments() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    final raw = await _channel.invokeMethod<List<dynamic>>('pickDocuments');
    return _toPaths(raw);
  }

  /// 应用由“分享到 Flashbyte”启动时带进来的文件，只返回一次。
  Future<List<FastFilePickerPath>> takeInitialSharedFiles() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'takeInitialSharedFiles',
    );
    return _toPaths(raw);
  }

  /// 应用运行期间从其它应用分享进来的文件。
  Stream<List<FastFilePickerPath>> get sharedFilesStream {
    if (!Platform.isAndroid) {
      return const Stream.empty();
    }
    return _sharedChannel.receiveBroadcastStream().map(_toPaths);
  }

  List<FastFilePickerPath> _toPaths(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    final paths = <FastFilePickerPath>[];
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final uri = item['uri'];
      if (uri is! String || uri.isEmpty) {
        continue;
      }
      final rawName = item['name'];
      final name = rawName is String && rawName.isNotEmpty
          ? rawName
          : uri.split('/').last;
      paths.add(FastFilePickerPath.fromPath(name, uri));
    }
    return paths;
  }
}
