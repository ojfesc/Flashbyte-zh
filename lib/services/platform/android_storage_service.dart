import 'dart:io';

import 'package:flutter/services.dart';

/// Reads the free space of the volume that receives partial transfer files.
///
/// Android writes received files into app storage first even when the chosen
/// destination is a SAF tree, so a large transfer needs that much free space
/// before it can start. Checking up front turns a mid-transfer
/// "no space left on device" failure into a clear message.
class AndroidStorageService {
  AndroidStorageService._();

  static const MethodChannel _channel = MethodChannel('flashbyte/storage');

  /// Free bytes on the app storage volume, or null when unavailable.
  static Future<int?> availableBytes() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final value = await _channel.invokeMethod<int>('availableBytes');
      if (value == null || value < 0) {
        return null;
      }
      return value;
    } on MissingPluginException {
      // Older installations without the native handler: skip the preflight.
      return null;
    } on PlatformException {
      return null;
    }
  }
}
