import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// The user's choice of light, dark, or following the phone; saved on the phone.
class Appearance extends ChangeNotifier {
  Appearance(Directory dataDir) : _file = File('${dataDir.path}/runtime/appearance');

  final File _file;
  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  /// Reads the saved choice; safe to call before the first frame.
  void load() {
    try {
      _mode = ThemeMode.values.byName(_file.readAsStringSync().trim());
    } on Object {
      _mode = ThemeMode.system;
    }
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _file.parent.create(recursive: true);
    await _file.writeAsString(mode.name);
  }
}
