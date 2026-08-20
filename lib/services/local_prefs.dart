import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local, account-free preferences.
///
/// Deliberately separate from [UserDataRepository], which persists the things
/// that belong to a *person* — saves, swipes, topics, region — and follows
/// them onto a second device. Appearance is not one of those. It belongs to
/// the *device*: a reader who wants dark on their phone at night has not
/// expressed a wish about any other screen they own, and a guest with no
/// account still deserves to have the choice remembered.
///
/// It also has to be readable synchronously at first frame. Everything the
/// repository holds arrives over the network some time after boot, which is
/// fine for a deck of articles and completely wrong for the theme — a theme
/// that arrives late is a flash of the wrong one.
///
/// Every accessor tolerates a missing/unwritable store, so the app keeps
/// working (just forgetful) if the platform channel is unavailable.
abstract final class LocalPrefs {
  static const _themeKey = 'bite.theme_mode';

  static SharedPreferences? _prefs;

  /// Awaited once in `main()` before the first frame.
  static Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('LocalPrefs: unavailable ($e); settings will not persist.');
    }
  }

  static ThemeMode get themeMode => switch (_prefs?.getString(_themeKey)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.setString(_themeKey, mode.name);
    } catch (e) {
      debugPrint('LocalPrefs: theme write failed ($e).');
    }
  }
}
