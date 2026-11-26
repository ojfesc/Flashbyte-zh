import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 读取系统粘贴板中的文本并写入临时文件；粘贴板没有文本时返回 null。
///
/// 发送端把它当作普通文件传输，接收端识别 `clipboard` 标记后只在内存里拼接
/// 内容，完成时写回粘贴板，不生成磁盘文件。
Future<File?> createClipboardTextFile() async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return null;
    }

    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'flashbyte_clipboard_${DateTime.now().microsecondsSinceEpoch}.txt',
    );
    await file.writeAsString(text);
    return file;
  } catch (_) {
    // 无法读取粘贴板或写临时文件时按“没有内容”处理，由界面提示。
    return null;
  }
}
