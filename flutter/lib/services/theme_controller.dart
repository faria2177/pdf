import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide light / dark / system appearance, remembered between launches.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController._() : super(ThemeMode.system);
  static final instance = ThemeController._();

  static const _key = 'theme_mode_v1';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = ThemeMode.values.firstWhere((m) => m.name == prefs.getString(_key), orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
