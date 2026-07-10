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

  /// Shared secret for the guardian-body Edge Function (x-body-secret
  /// header), which fetches Guardian article bodies for the reader. NOT a
  /// news-API key — the Guardian and NewsData keys live exclusively in Edge
  /// Function secrets and must never return to this bundle. This value only
  /// gates the body proxy against anonymous scripted calls; it deliberately
  /// unlocks nothing else (ingest-news and embed keep their own secrets).
  static String? get bodyFnSecret => _key('BODY_FN_SECRET');

  static String? get supabaseUrl => _key('SUPABASE_URL');

  static String? get supabaseAnonKey => _key('SUPABASE_ANON_KEY');

  /// True when persistence is configured. Without it the app runs entirely
  /// in-memory, exactly as before Phase 3.
  static bool get hasSupabase => supabaseUrl != null && supabaseAnonKey != null;

  /// Sign in with Apple is fully wired but OFF until the account-side setup
  /// is done. To activate:
  ///  1. Join the Apple Developer Program.
  ///  2. In Xcode (Runner target → Signing & Capabilities) add the
  ///     "Sign in with Apple" capability with your real team/bundle id.
  ///  3. In Supabase: Auth → Providers → Apple → enable, and add the app's
  ///     bundle id to "Client IDs" (native iOS validates the idToken
  ///     directly — no Services ID or .p8 secret needed).
  ///  4. In Supabase: Auth → Settings → enable "manual linking", so a
  ///     guest's Apple identity links onto their existing anonymous user.
  ///  5. Flip this to true (or build with
  ///     `--dart-define=BITE_APPLE_SIGN_IN=true`).
  static const bool appleSignInEnabled =
      bool.fromEnvironment('BITE_APPLE_SIGN_IN');
}
