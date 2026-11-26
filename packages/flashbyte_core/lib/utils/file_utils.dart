import 'dart:convert';
import 'dart:io';

/// Extracts a display-friendly file name from a path or URI.
String displayFileName(String value) {
  var name = value;
  try {
    name = Uri.decodeComponent(name);
  } catch (_) {
    // Use the original value when a provider returns malformed escaping.
  }
  if (name.startsWith('primary:')) {
    name = name.substring('primary:'.length);
  }
  final forwardSlash = name.lastIndexOf('/');
  final backSlash = name.lastIndexOf('\\');
  final separator = forwardSlash > backSlash ? forwardSlash : backSlash;
  return separator == -1 ? name : name.substring(separator + 1);
}

/// Characters that are not valid in a file name on every supported platform.
///
/// Windows is the strictest target: a name received from Android or Linux may
/// contain `: * ? " < > |` and creating it fails with a FileSystemException.
final RegExp _unsupportedNameCharacters = RegExp(r'[\x00-\x1F\x7F<>:"/\\|?*]');

/// Device names that Windows resolves to a device instead of a file. The check
/// has to run on the name without its extension ("CON.txt" is still CON).
const Set<String> _windowsReservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Longest file name accepted after sanitizing, in UTF-8 bytes. Most file
/// systems allow 255 bytes per component; staying below that leaves room for
/// the "(1)" suffix added when a name is already taken.
const int _maxFileNameBytes = 200;

/// Makes [value] safe to use as a single file name on the current platform.
///
/// Directory separators are dropped so a received name can never escape the
/// download directory, characters that Windows rejects are replaced, trailing
/// dots and spaces are removed on Windows, reserved device names are prefixed,
/// and the result is truncated to fit the file system limit while keeping the
/// extension.
String sanitizeFileName(String value, {required bool forWindows}) {
  var name = value;

  final forwardSlash = name.lastIndexOf('/');
  final backSlash = name.lastIndexOf('\\');
  final separator = forwardSlash > backSlash ? forwardSlash : backSlash;
  if (separator != -1) {
    name = name.substring(separator + 1);
  }

  name = name.replaceAll(_unsupportedNameCharacters, '_');
  name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

  if (forWindows) {
    // Windows silently strips these, which can turn "a." into a different
    // name than the one the sender sees.
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
  }

  if (name.isEmpty || name == '.' || name == '..') {
    name = 'file';
  }

  if (forWindows) {
    final dotIndex = name.indexOf('.');
    final stem = dotIndex == -1 ? name : name.substring(0, dotIndex);
    if (_windowsReservedNames.contains(stem.toUpperCase())) {
      name = '_$name';
    }
  }

  return _truncateUtf8FileName(name, _maxFileNameBytes);
}

/// Truncates [name] to [maxBytes] UTF-8 bytes, keeping the extension.
String _truncateUtf8FileName(String name, int maxBytes) {
  if (utf8.encode(name).length <= maxBytes) {
    return name;
  }

  final dotIndex = name.lastIndexOf('.');
  final hasExtension = dotIndex > 0 && name.length - dotIndex <= 16;
  final extension = hasExtension ? name.substring(dotIndex) : '';
  final stem = hasExtension ? name.substring(0, dotIndex) : name;
  final availableBytes = maxBytes - utf8.encode(extension).length;

  final buffer = StringBuffer();
  var usedBytes = 0;
  for (final rune in stem.runes) {
    final character = String.fromCharCode(rune);
    final characterBytes = utf8.encode(character).length;
    if (usedBytes + characterBytes > availableBytes) {
      break;
    }
    buffer.write(character);
    usedBytes += characterBytes;
  }

  final truncatedStem = buffer.isEmpty ? 'file' : buffer.toString();
  return '$truncatedStem$extension';
}

/// Generates a unique file name in [directory] to avoid collisions.
String generateUniqueFileName(String directory, String originalFileName) {
  final safeName = sanitizeFileName(
    originalFileName,
    forWindows: Platform.isWindows,
  );
  final originalFile = File("$directory/$safeName");
  if (!originalFile.existsSync()) {
    return safeName;
  }

  final lastDotIndex = safeName.lastIndexOf('.');
  final name = lastDotIndex > 0
      ? safeName.substring(0, lastDotIndex)
      : safeName;
  final extension = lastDotIndex > 0 ? safeName.substring(lastDotIndex) : '';

  int counter = 1;
  while (true) {
    final newFileName = '$name ($counter)$extension';
    final newFile = File("$directory/$newFileName");
    if (!newFile.existsSync()) {
      return newFileName;
    }
    counter++;
  }
}

/// Generates a user-facing error message for a client connection failure.
String clientConnectErrorMessage({
  required Object error,
  required String? host,
  required int? port,
  required bool useTLS,
}) {
  final details = error.toString();
  final endpoint = host == null || port == null
      ? 'the receiver'
      : '$host:$port';

  if (error is SocketException) {
    return 'Could not reach $endpoint. Check that the IP address and port are correct, both devices are on the same network, and the receiver server is running.\n\nDetails: $details';
  }

  if (details.toLowerCase().contains('hostname mismatch')) {
    return 'Could not verify the receiver TLS certificate name. Refresh discovery and try connecting to the receiver again.\n\nDetails: $details';
  }

  return useTLS
      ? 'This device has TLS enabled, but the other device appears to have TLS disabled or an incompatible certificate. Disable TLS on this device, or enable TLS on the other device, then try again.\n\nDetails: $details'
      : 'This device has TLS disabled, but the other device appears to require TLS. Enable TLS on this device, or disable TLS on the other device, then try again.\n\nDetails: $details';
}
