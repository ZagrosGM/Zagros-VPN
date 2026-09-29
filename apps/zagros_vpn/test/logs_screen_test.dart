import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zagros_vpn/l10n/generated/app_localizations.dart';
import 'package:zagros_vpn/src/logs/diagnostic_logs_service.dart';
import 'package:zagros_vpn/src/logs/logs_screen.dart';

void main() {
  group('LogsScreen Widget Tests', () {
    testWidgets('shows empty state when no logs exist', (tester) async {
      final service = DiagnosticLogsService();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LogsScreen(logsService: service),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No connection logs recorded yet.'), findsOneWidget);
      expect(find.byIcon(Icons.article_outlined), findsOneWidget);
      service.dispose();
    });

    testWidgets('renders log entries and action buttons when logs exist',
        (tester) async {
      final service = DiagnosticLogsService();
      service.log('Tunnel started on interface tun0');

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LogsScreen(logsService: service),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Tunnel started on interface tun0'),
          findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
      expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_sweep_outlined));
      await tester.pumpAndSettle();

      expect(find.text('No connection logs recorded yet.'), findsOneWidget);
      service.dispose();
    });
  });
}
