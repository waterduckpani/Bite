import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// All secrets come through here from the bundled `.env` file. Nothing else
/// in the app touches dotenv directly, and every accessor tolerates a
/// missing file so the app keeps running on mock data without keys.
abstract final class AppConfig {
  static bool _loaded = false;

  static Future<void> load() async {
    try {
      await dotenv.load(fileName: '.env');
      _loaded = true;
    } catch (e) {
      // No .env bundled (or unreadable): run keyless on mock data.
      debugPrint('AppConfig: no .env loaded ($e); using mock content.');
    }
  }

  static String? _key(String name) {
    if (!_loaded) return null;
    final value = dotenv.env[name]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static String? get guardianApiKey => _key('GUARDIAN_API_KEY');

  static String? get newsdataApiKey => _key('NEWSDATA_API_KEY');

  /// True when at least one live content source is configured.
  static bool get hasLiveContent =>
      guardianApiKey != null || newsdataApiKey != null;
}
