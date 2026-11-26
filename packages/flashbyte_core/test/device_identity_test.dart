import 'package:flashbyte_core/identity/device_identity.dart';
import 'package:test/test.dart';

void main() {
  group('generateDeviceId', () {
    test('returns UUID v4 format', () {
      final id = generateDeviceId();
      expect(
        id,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('generates unique IDs', () {
      final ids = List.generate(100, (_) => generateDeviceId());
      expect(ids.toSet().length, 100);
    });
  });
}
