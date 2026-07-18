import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kThemeKey = 'app_theme_mode';

class ThemeNotifier extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.light; // default: light

  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  /// Load saved preference from disk. Call once at startup.
  ///
  /// `dark` was previously missing from this switch, so choosing dark mode
  /// silently reverted to light on every restart.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = switch (prefs.getString(_kThemeKey)) {
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      'light' => ThemeMode.light,
      _ => ThemeMode.light, // first launch
    };
    notifyListeners();
  }

  Future<void> setDark() => _set(ThemeMode.dark);
  Future<void> setLight() => _set(ThemeMode.light);
  Future<void> setSystem() => _set(ThemeMode.system);

  Future<void> toggle() =>
      _mode == ThemeMode.dark ? setLight() : setDark();

  Future<void> _set(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeKey, mode.name);
  }
}
