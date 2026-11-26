import 'dart:io';

import 'package:flashbyte_core/utils/file_utils.dart';
import 'package:test/test.dart';

String repeat(String unit, int times) => List.filled(times, unit).join();

void main() {
  group('displayFileName', () {
    test('extracts filename from Unix path', () {
      expect(displayFileName('/home/user/file.txt'), 'file.txt');
    });

    test('extracts filename from Windows path', () {
      expect(displayFileName('C:\\Users\\file.txt'), 'file.txt');
    });

    test('decodes URL-encoded names', () {
      expect(displayFileName('my%20file.txt'), 'my file.txt');
    });

    test('handles primary: prefix from SAF', () {
      expect(displayFileName('primary:DCIM/photo.jpg'), 'photo.jpg');
    });

    test('returns plain name when no separator', () {
      expect(displayFileName('file.txt'), 'file.txt');
    });

    test('handles accented characters in filename', () {
      expect(displayFileName('/home/user/Oxygène.flac'), 'Oxygène.flac');
      expect(displayFileName('Café_concert.mp3'), 'Café_concert.mp3');
    });
  });

  group('generateUniqueFileName', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('flashbyte_test_');
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('returns original when file does not exist', () {
      final result = generateUniqueFileName(tmpDir.path, 'new_file.txt');
      expect(result, 'new_file.txt');
    });

    test('appends counter when file exists', () async {
      final existing = File('${tmpDir.path}/photo.jpg');
      await existing.writeAsString('data');
      final result = generateUniqueFileName(tmpDir.path, 'photo.jpg');
      expect(result, 'photo (1).jpg');
    });

    test('increments counter for multiple collisions', () async {
      await File('${tmpDir.path}/doc.pdf').writeAsString('a');
      await File('${tmpDir.path}/doc (1).pdf').writeAsString('b');
      final result = generateUniqueFileName(tmpDir.path, 'doc.pdf');
      expect(result, 'doc (2).pdf');
    });
  });

  group('sanitizeFileName', () {
    test('drops directory separators', () {
      expect(
        sanitizeFileName('../../etc/passwd', forWindows: false),
        'passwd',
      );
      expect(
        sanitizeFileName(r'C:\Windows\system32\evil.dll', forWindows: true),
        'evil.dll',
      );
    });

    test('replaces characters Windows rejects', () {
      expect(
        sanitizeFileName('report:final?.txt', forWindows: true),
        'report_final_.txt',
      );
    });

    test('prefixes reserved Windows device names', () {
      expect(sanitizeFileName('CON.txt', forWindows: true), '_CON.txt');
      expect(sanitizeFileName('nul', forWindows: true), '_nul');
      expect(sanitizeFileName('console.txt', forWindows: true), 'console.txt');
    });

    test('removes trailing dots and spaces on Windows only', () {
      expect(sanitizeFileName('report. ', forWindows: true), 'report');
      expect(sanitizeFileName('report. ', forWindows: false), 'report.');
    });

    test('collapses whitespace and falls back for empty names', () {
      expect(sanitizeFileName('  my   file.pdf  ', forWindows: false), 'my file.pdf');
      expect(sanitizeFileName('   ', forWindows: false), 'file');
      expect(sanitizeFileName('..', forWindows: false), 'file');
    });

    test('truncates long names but keeps the extension', () {
      final longName = '${repeat('a', 400)}.pdf';
      final result = sanitizeFileName(longName, forWindows: false);
      expect(result.endsWith('.pdf'), isTrue);
      expect(result.length, lessThan(400));
      expect(result.length, greaterThan(3));
    });  });

  group('clientConnectErrorMessage', () {
    test('formats SocketException', () {
      final msg = clientConnectErrorMessage(
        error: SocketException('Connection refused'),
        host: '192.168.1.1',
        port: 8050,
        useTLS: false,
      );
      expect(msg, contains('192.168.1.1:8050'));
      expect(msg, contains('Connection refused'));
    });

    test('formats hostname mismatch', () {
      final msg = clientConnectErrorMessage(
        error: Exception('Hostname mismatch'),
        host: null,
        port: null,
        useTLS: true,
      );
      expect(msg, contains('TLS certificate name'));
    });

    test('formats TLS mismatch', () {
      final msg = clientConnectErrorMessage(
        error: Exception('Some TLS error'),
        host: '10.0.0.1',
        port: 8050,
        useTLS: true,
      );
      expect(msg, contains('TLS enabled'));
    });
  });
}
