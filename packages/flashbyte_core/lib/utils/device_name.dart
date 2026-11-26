import 'dart:convert';

/// Rules shared by the sender and receiver for user-visible device names.
///
/// A device name is broadcast in the discovery hello, shown in device lists and
/// approval screens, stored in the trusted device list, and printed in
/// notifications. Keeping every path inside the same limits and character set
/// keeps the hello inside one UDP datagram and stops control or bidirectional
/// characters from being used to spoof another device in the UI.
class DeviceNameRules {
  const DeviceNameRules._();

  /// Longest accepted name in Unicode code points.
  static const int maxCharacters = 32;

  /// Longest accepted name in UTF-8 bytes.
  static const int maxUtf8Bytes = 96;

  /// Control characters that are replaced with a space so words stay separated.
  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F-\x9F]');

  /// Invisible and direction-changing code points that are removed entirely.
  static final RegExp _invisibleCharacters = RegExp(
    r'[\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]',
  );

  static final RegExp _whitespaceRuns = RegExp(r'\s+');

  /// All-uppercase model codes that contain a digit, such as "SM-G991B" or
  /// "2201117TG". Brand names without digits ("OPPO", "HTC") stay readable.
  static final RegExp _uppercaseMachineCode = RegExp(r'^[A-Z0-9][A-Z0-9\-/]{2,15}$');

  /// Lowercase build codes such as "m2012k11ac".
  static final RegExp _lowercaseMachineCode = RegExp(r'^[a-z]{1,2}\d{3,}[a-z0-9]*$');

  static final RegExp _digit = RegExp(r'\d');

  /// Removes control characters, invisible characters, newlines and repeated
  /// whitespace, then truncates the result to [maxCharacters] and
  /// [maxUtf8Bytes]. The returned value is safe to store, broadcast and render.
  static String sanitize(String raw) {
    var value = raw
        .replaceAll(_invisibleCharacters, '')
        .replaceAll(_controlCharacters, ' ');
    value = value.replaceAll(_whitespaceRuns, ' ').trim();
    if (value.isEmpty) {
      return '';
    }
    if (value.runes.length <= maxCharacters &&
        utf8.encode(value).length <= maxUtf8Bytes) {
      return value;
    }

    final buffer = StringBuffer();
    var usedBytes = 0;
    var usedCharacters = 0;
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final characterBytes = utf8.encode(character).length;
      if (usedCharacters + 1 > maxCharacters ||
          usedBytes + characterBytes > maxUtf8Bytes) {
        break;
      }
      buffer.write(character);
      usedBytes += characterBytes;
      usedCharacters++;
    }
    return buffer.toString();
  }

  /// Whether [value] is already a valid, non-empty device name.
  static bool isValid(String value) {
    return value.isNotEmpty &&
        value.runes.length <= maxCharacters &&
        utf8.encode(value).length <= maxUtf8Bytes;
  }

  /// Whether [value] looks like an internal model code instead of a name the
  /// user would recognize on the box.
  static bool isMachineCode(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (_uppercaseMachineCode.hasMatch(trimmed) && _digit.hasMatch(trimmed)) {
      return true;
    }
    return _lowercaseMachineCode.hasMatch(trimmed);
  }
}
