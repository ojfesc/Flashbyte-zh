import 'dart:io';

import 'package:saf/saf.dart';

class AndroidSafService {
  AndroidSafService._();

  /// 判断当前系统语言是否为中文。
  static bool get _isZh =>
      Platform.localeName.toLowerCase().startsWith('zh');

  static bool isTreeUri(String value) => value.startsWith('content://');

  static String formatTreeUriForDisplay(String uri) {
    final treeMatch = RegExp(r'tree/([^/?]+)').firstMatch(uri);
    if (treeMatch == null) {
      return uri;
    }

    final decoded = Uri.decodeComponent(treeMatch.group(1)!);
    if (decoded == 'primary:') {
      return _isZh ? '内部存储' : 'Internal storage';
    }
    if (decoded.startsWith('primary:')) {
      return decoded.replaceFirst('primary:', '');
    }
    return decoded.replaceAll(':', ':/');
  }

  static String trimPathForDisplay(String path) {
    if (isTreeUri(path)) {
      return formatTreeUriForDisplay(path);
    }

    if (path.startsWith('/storage/emulated/0/')) {
      return path.substring('/storage/emulated/0/'.length);
    }

    final homeMatch = RegExp(r'^/home/[^/]+/').firstMatch(path);
    if (homeMatch != null) {
      return path.substring(homeMatch.end);
    }

    return path;
  }

  static Future<SafDocumentFile?> pickDirectory({
    String? initialUri,
    bool writePermission = true,
  }) {
    final saf = Saf();
    return saf.pickDirectory(
      initialUri: initialUri,
      writePermission: writePermission,
      persistablePermission: true,
    );
  }

  /// 递归列出 SAF 目录树下的所有文件。
  ///
  /// 返回 (显示名, content:// 文档 URI)：SAF 目录没有文件系统路径，
  /// 调用方需把 uri 交给传输层，由 SAF 打开文件描述符读取内容。
  static Future<List<({String name, String uri})>> listFilesUnder(
    String treeUri,
  ) async {
    final files = <({String name, String uri})>[];
    await for (final entry in Saf().walk(treeUri)) {
      if (!entry.file.isDir) {
        files.add((name: entry.file.name, uri: entry.file.uri));
      }
    }
    return files;
  }
}
