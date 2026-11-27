import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the process alive while a file transfer is running on Android.
///
/// Without a foreground service Android is free to freeze or kill the process
/// as soon as the activity is not visible, even when the battery optimisation
/// exemption is granted. The service is started when the first file starts
/// moving and stopped when the last one finishes or the connection ends.
class TransferForegroundService {
  TransferForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'flashbyte/foreground_service',
  );

  static Future<void> start() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start');
    } on MissingPluginException {
      // Older installation without the native service.
    } on PlatformException {
      // Starting a foreground service is best effort; the transfer still works
      // while the app is visible.
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Nothing to stop.
    } on PlatformException {
      // The system may have stopped the service already.
    }
  }
}
