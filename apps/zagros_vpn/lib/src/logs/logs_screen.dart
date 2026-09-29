import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import 'diagnostic_logs_service.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({this.logsService, super.key});

  final DiagnosticLogsService? logsService;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final logsService = widget.logsService;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.logs),
        centerTitle: false,
        actions: <Widget>[
          if (logsService != null &&
              logsService.entries.isNotEmpty) ...<Widget>[
            IconButton(
              icon: const Icon(Icons.copy_rounded, size: 20),
              tooltip: localizations.copyLogs,
              onPressed: () => _copyLogs(context, logsService.entries),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, size: 22),
              tooltip: localizations.clearLogs,
              onPressed: () => setState(logsService.clear),
            ),
          ],
        ],
      ),
      body: logsService == null
          ? Center(child: Text(localizations.noLogsYet))
          : StreamBuilder<List<String>>(
              stream: logsService.stream,
              initialData: logsService.entries,
              builder: (context, snapshot) {
                final logs = snapshot.data ?? const <String>[];
                if (logs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          Icons.article_outlined,
                          size: 48,
                          color:
                              theme.colorScheme.onSurfaceVariant.withAlpha(120),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          localizations.noLogsYet,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _scrollToBottom());

                return Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withAlpha(120),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withAlpha(50),
                    ),
                  ),
                  child: ListView.builder(
                    controller: _scrollController,
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final line = logs[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: theme.colorScheme.onSurface,
                            height: 1.4,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }

  void _copyLogs(BuildContext context, List<String> logs) {
    Clipboard.setData(ClipboardData(text: logs.join('\n')));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).logsCopied)),
      );
  }
}
