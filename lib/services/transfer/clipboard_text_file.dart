import 'dart:io';

import 'package:flashbyte/app/controllers/app_locale_controller.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 读取系统粘贴板中的文本并写入临时文件；粘贴板没有文本时返回 null。
///
/// 发送端把它当作普通文件传输，接收端识别 `clipboard` 标记后只在内存里拼接
/// 内容，完成时写回粘贴板，不生成磁盘文件。系统分享进来的文本/链接也走这里。
Future<File?> createClipboardTextFile() async {
  String? text;
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    text = data?.text;
  } catch (_) {
    // 无法读取粘贴板时按“没有内容”处理，由界面提示。
    return null;
  }

  if (text == null || text.isEmpty) {
    return null;
  }
  return createTextFileFromString(text);
}

/// 把一段文本写成临时文件，供粘贴板与“分享文本/链接”共用同一套发送路径。
Future<File?> createTextFileFromString(String text) async {
  try {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'flashbyte_clipboard_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString(text);
    return file;
  } catch (_) {
    return null;
  }
}

/// 粘贴板文本的显示名，跟随应用语言，而不是系统语言。
String clipboardTextDisplayName() {
  final locale = AppLocaleController.instance.locale;
  final isChinese = locale != null
      ? locale.languageCode == 'zh'
      : Platform.localeName.toLowerCase().startsWith('zh');
  return isChinese ? '粘贴板文本.txt' : 'Clipboard.txt';
}

/// 清理本次启动之前留下的文本临时文件（粘贴板、分享文本、iOS 分享移交副本）。
///
/// 只删除 [before] 之前修改的文件，本次启动中新建的文件（包括刚分享进来的）
/// 不会被动到。
Future<void> cleanupSharedTextFiles({required DateTime before}) async {
  try {
    final directory = await getTemporaryDirectory();

    Future<void> removeOldFiles(Directory dir) async {
      if (!await dir.exists()) {
        return;
      }
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(before)) {
            await entity.delete();
          }
        } catch (_) {
          // 文件正被使用或已被删除时跳过。
        }
      }
    }

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('flashbyte_clipboard_')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(before)) {
          await entity.delete();
        }
      } catch (_) {
        // 文件正被使用或已被删除时跳过。
      }
    }

    await removeOldFiles(
      Directory('${directory.path}${Platform.pathSeparator}SharedFromApps'),
    );
  } catch (_) {
    // 拿不到临时目录时忽略，下一次启动再清理。
  }
}
