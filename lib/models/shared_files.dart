import 'package:fast_file_picker/fast_file_picker.dart';

/// 一次系统分享带来的内容。
///
/// 除了文件本身，还记录两类附加信息：
/// - [clipboardPaths]：由分享的文本/链接生成的文件，接收端应写回粘贴板，而不是落盘；
/// - [hasEphemeralFiles]：分享方没有授予持久化读权限，这些文件只在本次运行内可读。
class SharedFiles {
  const SharedFiles({
    required this.files,
    this.clipboardPaths = const <String>{},
    this.hasEphemeralFiles = false,
  });

  static const SharedFiles empty = SharedFiles(files: <FastFilePickerPath>[]);

  final List<FastFilePickerPath> files;
  final Set<String> clipboardPaths;
  final bool hasEphemeralFiles;

  bool get isEmpty => files.isEmpty;
}
