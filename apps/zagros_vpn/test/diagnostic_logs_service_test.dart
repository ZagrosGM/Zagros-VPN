import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/src/logs/diagnostic_logs_service.dart';

void main() {
  group('DiagnosticLogsService Tests', () {
    test('appends formatted logs with timestamp and respects capacity limit', () {
      final service = DiagnosticLogsService(maxEntries: 5);
      expect(service.entries, isEmpty);

      service.log('First event');
      service.log('Second event');
      expect(service.entries.length, 2);
      expect(service.entries[0], contains('First event'));
      expect(service.entries[1], contains('Second event'));

      for (var i = 3; i <= 10; i++) {
        service.log('Event $i');
      }
      expect(service.entries.length, 5);
      expect(service.entries.last, contains('Event 10'));
      expect(service.entries.first, contains('Event 6'));

      service.clear();
      expect(service.entries, isEmpty);
      service.dispose();
    });

    test('broadcasts log additions through stream', () async {
      final service = DiagnosticLogsService(maxEntries: 10);
      final logsFuture = service.stream.take(2).toList();

      service.log('Stream test 1');
      service.log('Stream test 2');

      final results = await logsFuture;
      expect(results.length, 2);
      expect(results[0].length, 1);
      expect(results[1].length, 2);
      service.dispose();
    });
  });
}
