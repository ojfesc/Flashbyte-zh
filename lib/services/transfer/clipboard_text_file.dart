import 'dart:io';

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
