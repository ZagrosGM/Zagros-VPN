import 'package:flutter/material.dart';

/// Shared presentation formatting. Both Official and Application screens
/// use these helpers so byte/date rendering is implemented exactly once.
String formatBytes(int value) {
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (value >= 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  return '$value B';
}

String formatDateTime(BuildContext context, DateTime value) {
  final localizations = MaterialLocalizations.of(context);
  final local = value.toLocal();
  return '${localizations.formatCompactDate(local)} '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}
