import 'dart:async';
import 'dart:io';

import 'package:fast_file_picker/fast_file_picker.dart';
import 'package:flashbyte/models/shared_files.dart';
import 'package:flashbyte/services/transfer/clipboard_text_file.dart';
import 'package:flutter/services.dart';

/// Android 上直接用系统文档选择器和分享意图拿 content:// URI。
///
/// 选文件/收分享时不再经过会复制文件内容的插件：几 GB 的文件复制到缓存既会
/// 长时间没有反应，也会把缓存占满。返回的 [FastFilePickerPath] 中
/// [FastFilePickerPath.name] 是显示名，[FastFilePickerPath.path] 存的是
/// content:// URI，传输层识别该前缀后按 SAF 文档流式读取。
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

  /// 应用由“分享到 Flashbyte”启动时带进来的内容，只返回一次。
  Future<SharedFiles> takeInitialSharedFiles() async {
    if (!Platform.isAndroid) {
      return SharedFiles.empty;
    }
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'takeInitialSharedFiles',
    );
    return _toSharedFiles(raw);
  }

  /// 应用运行期间从其它应用分享进来的内容。
  Stream<SharedFiles> get sharedFilesStream {
    if (!Platform.isAndroid) {
      return const Stream<SharedFiles>.empty();
    }
    return _sharedChannel.receiveBroadcastStream().asyncMap(_toSharedFiles);
  }

  List<FastFilePickerPath> _toPaths(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    final paths = <FastFilePickerPath>[];
    for (final item in raw) {
      final path = _pathFromEntry(item);
      if (path != null) {
        paths.add(path);
      }
    }
    return paths;
  }

  /// 分享内容既可能是文件 URI，也可能是纯文本；文本按粘贴板传输处理。
  Future<SharedFiles> _toSharedFiles(dynamic raw) async {
    if (raw is! List) {
      return SharedFiles.empty;
    }

    final files = <FastFilePickerPath>[];
    final clipboardPaths = <String>{};
    var hasEphemeralFiles = false;

    for (final item in raw) {
      if (item is! Map) {
        continue;
      }

      final text = item['text'];
      if (text is String && text.isNotEmpty) {
        final file = await createTextFileFromString(text);
        if (file == null) {
          continue;
        }
        files.add(
          FastFilePickerPath.fromPath(clipboardTextDisplayName(), file.path),
        );
        clipboardPaths.add(file.path);
        continue;
      }

      final path = _pathFromEntry(item);
      if (path == null) {
        continue;
      }
      files.add(path);
      // persistable == false 表示分享方没有授予持久化读权限。
      if (item['persistable'] == false) {
        hasEphemeralFiles = true;
      }
    }

    return SharedFiles(
      files: files,
      clipboardPaths: clipboardPaths,
      hasEphemeralFiles: hasEphemeralFiles,
    );
  }

  FastFilePickerPath? _pathFromEntry(dynamic item) {
    if (item is! Map) {
      return null;
    }
    final uri = item['uri'];
    if (uri is! String || uri.isEmpty) {
      return null;
    }
    final rawName = item['name'];
    final name = rawName is String && rawName.isNotEmpty
        ? rawName
        : uri.split('/').last;
    return FastFilePickerPath.fromPath(name, uri);
  }
}
