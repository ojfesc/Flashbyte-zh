import 'dart:convert';

import 'package:flashbyte_core/utils/device_name.dart';
import 'package:test/test.dart';

String repeat(String unit, int times) => List.filled(times, unit).join();

void main() {
  group('DeviceNameRules.sanitize', () {
    test('removes newlines, tabs and control characters', () {
      expect(DeviceNameRules.sanitize('Pixel\n\t7'), 'Pixel 7');
      expect(DeviceNameRules.sanitize('bad\u0000name'), 'bad name');
    });

    test('removes bidirectional override characters', () {
      expect(DeviceNameRules.sanitize('a\u202Eb'), 'ab');
      expect(DeviceNameRules.sanitize('a\u200Bb'), 'ab');
    });

    test('collapses repeated whitespace and trims', () {
      expect(DeviceNameRules.sanitize('  My    Phone  '), 'My Phone');
    });

    test('truncates to the character limit', () {
      final result = DeviceNameRules.sanitize(repeat('a', 100));
      expect(result.length, DeviceNameRules.maxCharacters);
    });

    test('truncates to the byte limit for multi-byte characters', () {
      final result = DeviceNameRules.sanitize(repeat('设', 100));
      expect(
        utf8.encode(result).length,
        lessThanOrEqualTo(DeviceNameRules.maxUtf8Bytes),
      );
      expect(result.length, lessThanOrEqualTo(DeviceNameRules.maxCharacters));
      expect(result, isNotEmpty);
    });

    test('returns empty for blank input', () {
      expect(DeviceNameRules.sanitize('   '), '');
      expect(DeviceNameRules.sanitize(''), '');
    });
  });

  group('DeviceNameRules.isValid', () {
    test('accepts a normal name', () {
      expect(DeviceNameRules.isValid('Pixel 7'), isTrue);
    });

    test('rejects empty and overlong names', () {
      expect(DeviceNameRules.isValid(''), isFalse);
      expect(
        DeviceNameRules.isValid(repeat('a', DeviceNameRules.maxCharacters + 1)),
        isFalse,
      );
    });
  });

  group('DeviceNameRules.isMachineCode', () {
    test('detects common Android model codes', () {
      expect(DeviceNameRules.isMachineCode('SM-G991B'), isTrue);
      expect(DeviceNameRules.isMachineCode('2201117TG'), isTrue);
      expect(DeviceNameRules.isMachineCode('CPH2451'), isTrue);
      expect(DeviceNameRules.isMachineCode('m2012k11ac'), isTrue);
    });

    test('keeps readable model names', () {
      expect(DeviceNameRules.isMachineCode('Pixel 7'), isFalse);
      expect(DeviceNameRules.isMachineCode('Redmi Note 12 Pro'), isFalse);
      expect(DeviceNameRules.isMachineCode('iPhone 15'), isFalse);
    });

    test('keeps brand names without digits', () {
      expect(DeviceNameRules.isMachineCode('OPPO'), isFalse);
      expect(DeviceNameRules.isMachineCode('HTC'), isFalse);
      expect(DeviceNameRules.isMachineCode('LG'), isFalse);
    });
  });
}
