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

  static Future<SafDocumentFile?> pickDirectory({String? initialUri}) {
    final saf = Saf();
    return saf.pickDirectory(
      initialUri: initialUri,
      writePermission: true,
      persistablePermission: true,
    );
  }
}
