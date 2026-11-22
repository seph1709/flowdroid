/// Reads apt's machine-readable status (`-o APT::Status-Fd=1`) into one
/// overall progress: downloading is the first half, installing the second.
class AptProgress {
  final _partial = StringBuffer();

  /// Feeds one line; returns the progress it reports, or null for other output.
  ({String step, double fraction})? feed(String line) {
    final parts = line.trim().split(':');
    if (parts.length < 3) return null;
    final pct = double.tryParse(parts[2]);
    if (pct == null) return null;
    return switch (parts[0]) {
      'dlstatus' => (step: 'Downloading packages', fraction: (pct / 100 * 0.5).clamp(0, 0.5)),
      'pmstatus' => (step: 'Installing', fraction: (0.5 + pct / 100 * 0.5).clamp(0.5, 1)),
      _ => null,
    };
  }

  /// Feeds output as it arrives (in any chunks); returns the latest progress in it.
  ({String step, double fraction})? feedChunk(String text) {
    _partial.write(text);
    final all = _partial.toString();
    final lines = all.split('\n');
    _partial
      ..clear()
      ..write(lines.removeLast());
    ({String step, double fraction})? latest;
    for (final line in lines) {
      latest = feed(line) ?? latest;
    }
    return latest;
  }
}
