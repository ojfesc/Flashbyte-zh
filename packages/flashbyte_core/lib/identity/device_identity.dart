import 'package:uuid/uuid.dart';

String generateDeviceId() {
  return const Uuid().v4();
}
