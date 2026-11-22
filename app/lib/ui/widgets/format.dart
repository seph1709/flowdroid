/// Short, locale-neutral formats for timestamps and durations.
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// `2026-11-21 08:30:05` in local time.
String formatTimestamp(DateTime t) {
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

/// `850 ms`, `4.2 s`, `3 min`.
String formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  return '${d.inMinutes} min';
}

/// `just now`, `5 min ago`, `3 h ago`, `2 days ago`, then the date.
String formatRelative(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
  final l = t.toLocal();
  return '${l.year}-${_two(l.month)}-${_two(l.day)}';
}

/// `1 item`, `3 items`.
String itemCount(int n) => n == 1 ? '1 item' : '$n items';

/// An engine error for people: `Fetch: NodeError: request failed` → `Fetch: request failed`.
/// Expression problems keep a readable label.
String readableError(String error) => error
    .replaceAll(RegExp(r'\b(NodeError|InputError|CronError): '), '')
    .replaceAll('ExpressionError: ', 'expression error: ');
