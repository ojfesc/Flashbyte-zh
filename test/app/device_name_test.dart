import 'package:flashbyte/app/device_name.dart';
import 'package:flutter_test/flutter_test.dart';

String repeat(String unit, int times) => List.filled(times, unit).join();

void main() {
  group('iosModelName', () {
    test('maps known hardware identifiers to marketing names', () {
      expect(DeviceName.iosModelName('iPhone15,2'), 'iPhone 14 Pro');
      expect(DeviceName.iosModelName('iPhone16,2'), 'iPhone 15 Pro Max');
      expect(DeviceName.iosModelName('iPad13,18'), 'iPad');
    });

    test('falls back to the product family for unknown identifiers', () {
      expect(DeviceName.iosModelName('iPhone99,1'), 'iPhone');
      expect(DeviceName.iosModelName('iPad99,1'), 'iPad');
    });

    test('returns empty for a blank identifier', () {
      expect(DeviceName.iosModelName('   '), '');
    });
  });

  group('normalize', () {
    test('cleans control characters and repeated whitespace', () {
      expect(DeviceName.normalize('  My\nPhone  '), 'My Phone');
    });

    test('truncates long input to the limit', () {
      expect(
        DeviceName.normalize(repeat('a', 80)).length,
        DeviceName.maxCharacters,
      );
    });
  });

  group('validate', () {
    test('reports an empty name', () {
      expect(DeviceName.validate(''), DeviceNameError.empty);
    });

    test('reports an overlong name', () {
      expect(
        DeviceName.validate(repeat('a', DeviceName.maxCharacters + 1)),
        DeviceNameError.tooLong,
      );
    });

    test('accepts a valid name', () {
      expect(DeviceName.validate('Pixel 7'), isNull);
    });
  });

  group('fallbackFor', () {
    test('follows the app language', () {
      expect(DeviceName.fallbackFor('zh'), '未知设备');
      expect(DeviceName.fallbackFor('en'), 'Unknown device');
    });
  });
}
