import 'dart:async';

/// In-memory bounded diagnostic log buffer for the Logs tab.
///
/// Records sanitized tunnel lifecycle events and traffic statistics
/// without exposing credentials, private keys, or raw configurations.
class DiagnosticLogsService {
  DiagnosticLogsService({this.maxEntries = 500});

  final int maxEntries;
  final List<String> _entries = <String>[];
  final StreamController<List<String>> _controller =
      StreamController<List<String>>.broadcast();

  Stream<List<String>> get stream => _controller.stream;
  List<String> get entries => List<String>.unmodifiable(_entries);

  void log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final formatted = '[$timestamp] $message';
    _entries.add(formatted);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    _controller.add(List<String>.unmodifiable(_entries));
  }

  void clear() {
    _entries.clear();
    _controller.add(const <String>[]);
  }

  void dispose() {
    _controller.close();
  }
}
