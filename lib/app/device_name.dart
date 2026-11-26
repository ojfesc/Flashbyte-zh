import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flashbyte/l10n/app_localizations.dart';
import 'package:flashbyte_core/utils/device_name.dart';
import 'package:flutter/material.dart';

/// Resolves and validates the name this device shows to other devices.
///
/// The name is user visible in discovery lists, approval screens, trusted
/// device lists and notifications, so every value that leaves this class has
/// already passed [DeviceNameRules.sanitize].
class DeviceName {
  const DeviceName._();

  /// Error reported when a typed name cannot be saved.
  static DeviceNameError? validate(String value) {
    if (value.isEmpty) {
      return DeviceNameError.empty;
    }
    if (!DeviceNameRules.isValid(value)) {
      return DeviceNameError.tooLong;
    }
    return null;
  }

  /// Normalizes a name typed by the user.
  static String normalize(String raw) => DeviceNameRules.sanitize(raw);

  /// Longest name accepted by the editor.
  static int get maxCharacters => DeviceNameRules.maxCharacters;
  /// Best hardware name available on this platform, or an empty string when
  /// nothing readable can be resolved.
  static Future<String> resolveModelName({
    required DeviceInfoPlugin deviceInfo,
  }) async {
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        final model = DeviceNameRules.sanitize(androidInfo.model);
        if (model.isNotEmpty && !DeviceNameRules.isMachineCode(model)) {
          return model;
        }
        final brand = DeviceNameRules.sanitize(androidInfo.brand);
        if (brand.isNotEmpty) {
          return _capitalize(brand);
        }
        final manufacturer = DeviceNameRules.sanitize(androidInfo.manufacturer);
        if (manufacturer.isNotEmpty) {
          return _capitalize(manufacturer);
        }
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosModelName(iosInfo.utsname.machine);
      }
    } catch (_) {
      // Fall through to the hostname based fallback below.
    }

    final hostname = DeviceNameRules.sanitize(Platform.localHostname);
    if (hostname.isNotEmpty && hostname.toLowerCase() != 'localhost') {
      return _stripHostSuffix(hostname);
    }
    return '';
  }

  /// Maps an iOS hardware identifier ("iPhone15,2") to a name users recognize.
  ///
  /// Identifiers that are not in the table fall back to the product family so
  /// the UI never shows a raw "iPhone15,2".
  static String iosModelName(String machineIdentifier) {
    final identifier = machineIdentifier.trim();
    if (identifier.isEmpty) {
      return '';
    }
    final mapped = _iosMarketingNames[identifier];
    if (mapped != null) {
      return mapped;
    }
    if (identifier.startsWith('iPhone')) {
      return 'iPhone';
    }
    if (identifier.startsWith('iPad')) {
      return 'iPad';
    }
    if (identifier.startsWith('iPod')) {
      return 'iPod';
    }
    if (identifier.startsWith('Mac')) {
      return 'Mac';
    }
    return DeviceNameRules.sanitize(identifier);
  }

  /// Fallback shown when no hardware name exists, localized with the app
  /// language (not the system language, which can differ from the UI).
  static String fallbackFor(String languageCode) {
    final locale = languageCode == 'zh'
        ? const Locale('zh')
        : languageCode == 'en'
        ? const Locale('en')
        : Platform.localeName.toLowerCase().startsWith('zh')
        ? const Locale('zh')
        : const Locale('en');
    return AppLocalizations(locale).unknownDevice;
  }

  static String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }

  static String _stripHostSuffix(String hostname) {
    final lower = hostname.toLowerCase();
    for (final suffix in const ['.local', '.lan', '.home']) {
      if (lower.endsWith(suffix)) {
        return hostname.substring(0, hostname.length - suffix.length);
      }
    }
    return hostname;
  }

  /// Marketing names for the common iPhone and iPad hardware identifiers.
  static const Map<String, String> _iosMarketingNames = {
    'iPhone10,1': 'iPhone 8',
    'iPhone10,2': 'iPhone 8 Plus',
    'iPhone10,3': 'iPhone X',
    'iPhone10,4': 'iPhone 8',
    'iPhone10,5': 'iPhone 8 Plus',
    'iPhone10,6': 'iPhone X',
    'iPhone11,2': 'iPhone XS',
    'iPhone11,4': 'iPhone XS Max',
    'iPhone11,6': 'iPhone XS Max',
    'iPhone11,8': 'iPhone XR',
    'iPhone12,1': 'iPhone 11',
    'iPhone12,3': 'iPhone 11 Pro',
    'iPhone12,5': 'iPhone 11 Pro Max',
    'iPhone12,8': 'iPhone SE',
    'iPhone13,1': 'iPhone 12 mini',
    'iPhone13,2': 'iPhone 12',
    'iPhone13,3': 'iPhone 12 Pro',
    'iPhone13,4': 'iPhone 12 Pro Max',
    'iPhone14,2': 'iPhone 13 Pro',
    'iPhone14,3': 'iPhone 13 Pro Max',
    'iPhone14,4': 'iPhone 13 mini',
    'iPhone14,5': 'iPhone 13',
    'iPhone14,6': 'iPhone SE',
    'iPhone14,7': 'iPhone 14',
    'iPhone14,8': 'iPhone 14 Plus',
    'iPhone15,2': 'iPhone 14 Pro',
    'iPhone15,3': 'iPhone 14 Pro Max',
    'iPhone15,4': 'iPhone 15',
    'iPhone15,5': 'iPhone 15 Plus',
    'iPhone16,1': 'iPhone 15 Pro',
    'iPhone16,2': 'iPhone 15 Pro Max',
    'iPhone17,1': 'iPhone 16 Pro',
    'iPhone17,2': 'iPhone 16 Pro Max',
    'iPhone17,3': 'iPhone 16',
    'iPhone17,4': 'iPhone 16 Plus',
    'iPad11,1': 'iPad mini',
    'iPad11,2': 'iPad mini',
    'iPad11,3': 'iPad Air',
    'iPad11,4': 'iPad Air',
    'iPad12,1': 'iPad',
    'iPad12,2': 'iPad',
    'iPad13,1': 'iPad Air',
    'iPad13,2': 'iPad Air',
    'iPad13,4': 'iPad Pro',
    'iPad13,5': 'iPad Pro',
    'iPad13,6': 'iPad Pro',
    'iPad13,7': 'iPad Pro',
    'iPad13,8': 'iPad Pro',
    'iPad13,9': 'iPad Pro',
    'iPad13,10': 'iPad Pro',
    'iPad13,11': 'iPad Pro',
    'iPad13,16': 'iPad Air',
    'iPad13,17': 'iPad Air',
    'iPad13,18': 'iPad',
    'iPad13,19': 'iPad',
    'iPad14,1': 'iPad mini',
    'iPad14,2': 'iPad mini',
    'iPad14,3': 'iPad Pro',
    'iPad14,4': 'iPad Pro',
    'iPad14,5': 'iPad Pro',
    'iPad14,6': 'iPad Pro',
    'iPad16,3': 'iPad Pro',
    'iPad16,4': 'iPad Pro',
    'iPad16,5': 'iPad Pro',
    'iPad16,6': 'iPad Pro',
  };
}

/// Validation failures for a typed device name.
enum DeviceNameError { empty, tooLong }
