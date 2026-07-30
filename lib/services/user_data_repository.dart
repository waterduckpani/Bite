import 'dart:async';
import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../data/mock_articles.dart';
import '../data/palettes.dart';
import '../models/article.dart';
import '../models/region.dart';
import '../models/story_tracker.dart';

/// How an email OTP will resolve once verified.
enum EmailOtpMode {
  /// The email gets attached to the current (anonymous) user — the user id
  /// is unchanged, so saves and swipe history carry over.
  linkToGuest,

  /// The email already belongs to another account; verifying signs into
  /// that account (replacing the guest session on this device).
  signInExisting,
}

/// Everything hydrated from Supabase at startup.
class HydratedUserData {
  const HydratedUserData({
    required this.onboarded,
    required this.seenTutorialVersion,
    required this.categories,
    required this.saved,
    required this.savedAt,
    required this.dismissedIds,
    required this.trackers,
    required this.region,
  });

  final bool onboarded;

  /// Highest gesture-tutorial version this user has acknowledged (0 = never).
  final int seenTutorialVersion;

  final Set<Category> categories;

  /// Saved articles, oldest save first (matches AppState's internal order).
  final List<Article> saved;

  /// When each save happened, keyed by article id — what the Saved screen
  /// sorts "recently saved" by. Insertion order alone can't survive a
  /// hydration that interleaves with local saves.
  final Map<String, DateTime> savedAt;

  /// Reject-swiped (left) article ids since the last feed reset.
  final Set<String> dismissedIds;

  /// Story trackers, newest-activity first (Phase 13).
  final List<StoryTracker> trackers;

  /// The user's selected region (defaults to [Region.global], no boost).
  final Region region;
}

/// Supabase-backed persistence for per-user state, with anonymous auth as
/// the identity layer.
///
/// Writes are optimistic: callers update local state immediately while the
/// matching operation joins an in-order queue that flushes to Supabase and
/// retries while unreachable — the UI never waits on the network. When
/// Supabase isn't configured (or initialization fails) the repository is
/// disabled and every call is a no-op, leaving the app fully in-memory.
class UserDataRepository {
  UserDataRepository._(this._enabled);

  /// Initializes Supabase and returns a live repository, or a disabled one
  /// when unconfigured/unavailable. Never throws.
  static Future<UserDataRepository> init() async {
    if (!AppConfig.hasSupabase) return UserDataRepository._(false);
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl!,
        // Accepts the new sb_publishable_… key or a legacy anon JWT.
        publishableKey: AppConfig.supabaseAnonKey!,
      );
      return UserDataRepository._(true);
    } catch (e) {
      debugPrint('UserDataRepository: Supabase init failed ($e); in-memory.');
      return UserDataRepository._(false);
    }
  }

  final bool _enabled;
  bool get enabled => _enabled;

  SupabaseClient get _client => Supabase.instance.client;

  /// Signs in anonymously when there's no restored session, so every user
  /// has an auth.users id. Session persistence itself is automatic.
  Future<bool> _ensureSession() async {
    final auth = _client.auth;
    if (auth.currentSession != null) return true;
    try {
      await auth.signInAnonymously().timeout(const Duration(seconds: 8));
      return true;
    } catch (e) {
      debugPrint('UserDataRepository: anonymous sign-in failed ($e)');
      return false;
    }
  }

  String get _uid => _client.auth.currentUser!.id;

  // -- Auth ------------------------------------------------------------------

  /// The signed-in email, or null while browsing as a guest. A pending
  /// (unverified) email change on an anonymous user keeps this null — the
  /// user stays a guest until the code is verified.
  String? get accountEmail {
    if (!_enabled) return null;
    final email = _client.auth.currentUser?.email;
    return (email == null || email.isEmpty) ? null : email;
  }

  /// Emails a 6-digit code and reports how verifying it will resolve.
  ///
  /// Guests are upgraded in place: the email is attached to the existing
  /// anonymous user via [GoTrueClient.updateUser], so the user id — and with
  /// it every save and swipe — is preserved. Only when the email already
  /// belongs to another account do we fall back to a plain OTP sign-in to
  /// that account. Throws [AuthException] on failure (e.g. rate limits).
  Future<EmailOtpMode> sendEmailOtp(String email) async {
    if (!await _ensureSession()) {
      throw const AuthException('No connection. Try again in a moment.');
    }
    if (accountEmail == null) {
      try {
        await _client.auth
            .updateUser(UserAttributes(email: email))
            .timeout(const Duration(seconds: 12));
        return EmailOtpMode.linkToGuest;
      } on AuthException catch (e) {
        // 422 email_exists: the address is already registered.
        if (e.code != 'email_exists' && e.statusCode != '422') rethrow;
      }
    }
    await _client.auth
        .signInWithOtp(email: email, shouldCreateUser: false)
        .timeout(const Duration(seconds: 12));
    return EmailOtpMode.signInExisting;
  }

  /// Verifies the emailed code. Returns true when the device switched to a
  /// different user id (existing account) — the caller must re-hydrate.
  Future<bool> verifyEmailOtp(
      String email, String code, EmailOtpMode mode) async {
    final before = _client.auth.currentUser?.id;
    await _client.auth
        .verifyOTP(
          email: email,
          token: code,
          type: mode == EmailOtpMode.linkToGuest
              ? OtpType.emailChange
              : OtpType.email,
        )
        .timeout(const Duration(seconds: 12));
    final after = _client.auth.currentUser?.id;
    debugPrint('UserDataRepository: verified $email '
        '(uid $before -> $after, ${before == after ? 'linked' : 'switched'})');
    return before != after;
  }

  /// Signs out and immediately starts a fresh guest (anonymous) session, so
  /// the app never runs without an identity to persist against.
  Future<void> signOut() async {
    try {
      await _client.auth.signOut().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('UserDataRepository: sign-out failed ($e)');
    }
    await _ensureSession();
  }

  /// Native Apple sign-in. Dormant until [AppConfig.appleSignInEnabled] —
  /// see the activation checklist there before flipping the flag.
  Future<bool> signInWithApple() async {
    if (!await _ensureSession()) {
      throw const AuthException('No connection. Try again in a moment.');
    }
    final rawNonce = _client.auth.generateRawNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );
    final idToken = credential.identityToken;
    if (idToken == null) {
      throw const AuthException('Apple returned no identity token.');
    }

    final before = _client.auth.currentUser?.id;
    // Guests link the Apple identity onto their existing user (id preserved,
    // needs "manual linking" enabled in Supabase); everyone else signs in.
    if (accountEmail == null && _client.auth.currentUser != null) {
      try {
        await _client.auth.linkIdentityWithIdToken(
          provider: OAuthProvider.apple,
          idToken: idToken,
          nonce: rawNonce,
        );
        return false; // uid unchanged
      } on AuthException catch (e) {
        // Identity already belongs to an account — sign into it instead.
        debugPrint('UserDataRepository: Apple link failed (${e.code}), '
            'signing in directly');
      }
    }
    await _client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );
    return before != _client.auth.currentUser?.id;
  }

  // -- Hydration -------------------------------------------------------------

  /// Loads profile, category prefs, saves, and post-reset dismissals.
  /// Returns null (leaving in-memory defaults intact) when disabled or
  /// unreachable. "Dismissals" here are Phase 11 `reject` swipes (left).
  Future<HydratedUserData?> hydrate() async {
    if (!_enabled) return null;
    try {
      if (!await _ensureSession()) return null;
      final results = await Future.wait(<Future<dynamic>>[
        _client.from('profiles').select().eq('id', _uid).maybeSingle(),
        _client.from('category_prefs').select('category').eq('user_id', _uid),
        _client
            .from('saves')
            .select('saved_at, articles(*)')
            .eq('user_id', _uid)
            .order('saved_at', ascending: true),
      ]).timeout(const Duration(seconds: 8));

      final profile = results[0] as Map<String, dynamic>?;
      final resetAt = profile?['feed_reset_at'] as String?;

      var rejectSwipes = _client
          .from('swipe_events')
          .select('article_id')
          .eq('user_id', _uid)
          .eq('direction', 'reject');
      if (resetAt != null) rejectSwipes = rejectSwipes.gt('created_at', resetAt);
      final dismissed =
          await rejectSwipes.timeout(const Duration(seconds: 8));

      // Trackers are fetched independently so a pre-deploy (RPC-missing) or
      // transient failure can't abort the rest of hydration.
      final trackers = await fetchTrackers() ?? const <StoryTracker>[];

      final data = HydratedUserData(
        onboarded: profile?['onboarded'] as bool? ?? false,
        seenTutorialVersion:
            (profile?['gesture_tutorial_version'] as num?)?.toInt() ?? 0,
        categories: {
          for (final row in results[1] as List)
            if (Category.values.asNameMap()[row['category']] case final c?) c,
        },
        saved: [
          for (final row in results[2] as List)
            if (_articleFromRow(row['articles'] as Map<String, dynamic>)
                case final a?)
              a,
        ],
        savedAt: {
          for (final row in results[2] as List)
            if (_articleFromRow(row['articles'] as Map<String, dynamic>)
                case final a?)
              if (DateTime.tryParse(row['saved_at'] as String? ?? '')
                  case final at?)
                a.id: at.toLocal(),
        },
        dismissedIds: {for (final row in dismissed) row['article_id'] as String},
        trackers: trackers,
        region: Region.fromTag(profile?['region'] as String?),
      );
      debugPrint('UserDataRepository: hydrated onboarded=${data.onboarded}, '
          '${data.categories.length} prefs, ${data.saved.length} saves, '
          '${data.dismissedIds.length} dismissed, '
          '${data.trackers.length} trackers');
      return data;
    } catch (e) {
      debugPrint('UserDataRepository: hydrate failed ($e); in-memory.');
      return null;
    }
  }

  /// The reader's own swipe history, joined to each article's topic and
  /// outlet, newest first — what the Profile screen reconstructs their taste
  /// profile from. Read-only and self-scoped by RLS.
  ///
  /// Fetches more rows than the server's window uses, because rows whose
  /// article has since been purged carry no topic and would otherwise silently
  /// shrink the sample.
  Future<List<Map<String, dynamic>>?> fetchSwipeHistory({int limit = 300}) async {
    if (!_enabled) return null;
    try {
      if (!await _ensureSession()) return null;
      final rows = await _client
          .from('swipe_events')
          .select('direction, created_at, articles(category, source_name)')
          .eq('user_id', _uid)
          .order('created_at', ascending: false)
          .limit(limit)
          .timeout(const Duration(seconds: 8));
      return [for (final row in rows) row];
    } catch (e) {
      debugPrint('UserDataRepository: swipe history failed ($e)');
      return null;
    }
  }

  // -- Personalized feed (Phases 7–8) ------------------------------------------
  // The candidate pool is ingested server-side (ingest-news cron); the client
  // only reads the ranked result. Swipe/save writes still upsert metadata for
  // the odd article the server doesn't know (mock, or fallback-fetched).

  /// Ranked unseen articles from the get_personalized_feed RPC, or null when
  /// disabled/unreachable/empty — callers keep their existing pool.
  Future<List<Article>?> fetchPersonalizedFeed({int limit = 200}) async {
    if (!_enabled) return null;
    try {
      if (!await _ensureSession()) return null;
      final rows = await _client
          .rpc('get_personalized_feed', params: {'p_limit': limit})
          .timeout(const Duration(seconds: 8));
      final ranked = [
        for (final row in rows as List)
          if (_articleFromRow(row as Map<String, dynamic>) case final a?) a,
      ];
      debugPrint(
          'UserDataRepository: personalized feed returned ${ranked.length}');
      return ranked.isEmpty ? null : ranked;
    } catch (e) {
      debugPrint('UserDataRepository: personalized feed failed ($e)');
      return null;
    }
  }

  // -- Story trackers (Phase 13) ---------------------------------------------
  // A tracker's centroid + tags are seeded server-side from the article's
  // existing embedding (create_tracker), so creation is an RPC,
  // not a plain insert. Everything else is a normal RLS-scoped table write or
  // read RPC. Matching (tracker_articles inserts) happens server-side.

  /// The Tracked list: trackers with counts + latest development, newest first.
  /// Null when disabled/unreachable — callers keep their existing list.
  Future<List<StoryTracker>?> fetchTrackers() async {
    if (!_enabled) return null;
    try {
      if (!await _ensureSession()) return null;
      final rows = await _client
          .rpc('get_trackers')
          .timeout(const Duration(seconds: 8));
      return [
        for (final row in rows as List)
          if (StoryTracker.fromRow(row as Map<String, dynamic>) case final t?)
            t,
      ];
    } catch (e) {
      debugPrint('UserDataRepository: fetch trackers failed ($e)');
      return null;
    }
  }

  /// A tracker's developing timeline, newest match first. Empty when the
  /// tracker has no articles yet; null on failure.
  Future<List<Article>?> fetchTrackerArticles(String trackerId) async {
    if (!_enabled) return null;
    try {
      if (!await _ensureSession()) return null;
      final rows = await _client
          .rpc('get_tracker_articles', params: {'p_tracker_id': trackerId})
          .timeout(const Duration(seconds: 8));
      return [
        for (final row in rows as List)
          if (_articleFromRow(row as Map<String, dynamic>) case final a?) a,
      ];
    } catch (e) {
      debugPrint('UserDataRepository: fetch tracker articles failed ($e)');
      return null;
    }
  }

  /// Creates a tracker seeded from [article], reusing its server-side
  /// embedding. The id is client-generated so the UI is
  /// optimistic; the RPC is idempotent on (user, seed story).
  void createTracker(String trackerId, Article article, String title) {
    _enqueue(() async {
      await _upsertArticle(article);
      await _client.rpc('create_tracker', params: {
        'p_id': trackerId,
        'p_seed_article_id': article.id,
        'p_title': title,
      });
    });
  }

  void renameTracker(String trackerId, String title) {
    _enqueue(() => _client
        .from('story_trackers')
        .update({'title': title})
        .eq('id', trackerId)
        .eq('user_id', _uid));
  }

  /// Muting stops future matching without deleting history.
  void setTrackerMuted(String trackerId, bool muted) {
    _enqueue(() => _client
        .from('story_trackers')
        .update({'muted': muted})
        .eq('id', trackerId)
        .eq('user_id', _uid));
  }

  /// Deletes a tracker and (by cascade) its tracker_articles rows only — the
  /// underlying articles, saves, and swipe history are untouched.
  void deleteTracker(String trackerId) {
    _enqueue(() => _client
        .from('story_trackers')
        .delete()
        .eq('id', trackerId)
        .eq('user_id', _uid));
  }

  /// Clears a tracker's unread articles and stamps last_viewed_at.
  void markTrackerSeen(String trackerId) {
    _enqueue(() =>
        _client.rpc('mark_tracker_seen', params: {'p_tracker_id': trackerId}));
  }

  // -- Writes (optimistic, queued in order) ----------------------------------

  void setOnboarded() {
    _enqueue(() => _client.from('profiles').upsert({
          'id': _uid,
          'onboarded': true,
        }));
  }

  /// Persists the user's selected region (Phase 16) and RESOLVES once the
  /// server has it. Stored as the registry TAG ('GLOBAL' | 'US' | 'UK' | 'EU'
  /// | 'IN' | 'AU'), not the enum name, so get_personalized_feed compares it
  /// directly against publishers.region — one vocabulary, no mapping table to
  /// drift out of sync.
  ///
  /// AWAITED, unlike every other write here, and that is the whole point.
  /// The rest are fire-and-forget through the offline queue because the client
  /// already knows the answer and doesn't need the round trip. This one is
  /// different: the region boost is applied SERVER-side — get_personalized_feed
  /// reads profiles.region — so Part E's instant re-rank would race the write
  /// and re-query under the OLD region, making a deliberate change look like it
  /// did nothing.
  ///
  /// The queue is still the fallback: a failed direct write is enqueued, so the
  /// preference is never lost — it just takes effect on the next query rather
  /// than this one.
  Future<void> setRegion(Region region) async {
    if (!_enabled) return;
    final row = {'id': _uid, 'region': region.tag};
    try {
      if (!await _ensureSession()) throw StateError('no session');
      await _client
          .from('profiles')
          .upsert(row)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('UserDataRepository: region write deferred to queue ($e)');
      _enqueue(() => _client.from('profiles').upsert(row));
    }
  }

  /// Persists that the user has seen the gesture tutorial at [version].
  void setGestureTutorialSeen(int version) {
    _enqueue(() => _client.from('profiles').upsert({
          'id': _uid,
          'gesture_tutorial_version': version,
        }));
  }

  /// Replaces the user's category prefs with [picks].
  void replaceCategoryPrefs(Set<Category> picks) {
    final categories = [for (final c in picks) c.name];
    _enqueue(() async {
      await _client.from('category_prefs').delete().eq('user_id', _uid);
      if (categories.isNotEmpty) {
        await _client.from('category_prefs').insert([
          for (final c in categories) {'user_id': _uid, 'category': c},
        ]);
      }
    });
  }

  void saveArticle(Article article) {
    _enqueue(() async {
      await _upsertArticle(article);
      await _client.from('saves').upsert({
        'user_id': _uid,
        'article_id': article.id,
      });
    });
  }

  void removeSave(String articleId) {
    _enqueue(() => _client
        .from('saves')
        .delete()
        .eq('user_id', _uid)
        .eq('article_id', articleId));
  }

  /// Appends one implicit-feedback row. [direction] is a Phase 11 signal:
  /// `reject` (left) / `read` (right) / `save` (down), or `opened` (up/tap) —
  /// the last is non-terminal and layers an additive positive boost on top of
  /// the eventual resolution, so a single card can log both an `opened` row
  /// and its resolving row.
  void recordSwipe(Article article, String direction) {
    _enqueue(() async {
      await _upsertArticle(article);
      await _client.from('swipe_events').insert({
        'user_id': _uid,
        'article_id': article.id,
        'direction': direction,
      });
    });
  }

  /// Records a Phase 14 referral event: `impression` when a card is actually
  /// shown, `linkout` when the reader taps or swipes through to the publisher.
  ///
  /// The publisher is resolved SERVER-SIDE from the article row, so the client
  /// never sends (and cannot forge) attribution. Legacy Guardian-API, mock and
  /// unknown articles are ignored by the RPC — there is no publisher to credit.
  ///
  /// This is what makes "Bite is a referrer, not a replacement" a measurable
  /// claim rather than a stated one: it is the input to the per-publisher CTR
  /// report. Queued like every other write, so it survives being offline.
  void recordReferral(String articleId, String eventType) {
    _enqueue(() => _client.rpc('record_referral', params: {
          'p_article_id': articleId,
          'p_event_type': eventType,
        }));
  }

  /// Feed resets move a watermark instead of deleting swipe history:
  /// hydration only counts left-swipes newer than this.
  void recordFeedReset() {
    final at = DateTime.now().toUtc().toIso8601String();
    _enqueue(() => _client.from('profiles').upsert({
          'id': _uid,
          'feed_reset_at': at,
        }));
  }

  // -- Offline queue ---------------------------------------------------------

  final List<Future<void> Function()> _queue = [];
  bool _flushing = false;
  Timer? _retry;

  void _enqueue(Future<void> Function() op) {
    if (!_enabled) return;
    _queue.add(op);
    _flush();
  }

  Future<void> _flush() async {
    if (_flushing || !_enabled || _queue.isEmpty) return;
    _flushing = true;
    try {
      if (!await _ensureSession()) throw StateError('no session');
      while (_queue.isNotEmpty) {
        await _queue.first().timeout(const Duration(seconds: 10));
        _queue.removeAt(0);
      }
    } catch (e) {
      debugPrint('UserDataRepository: sync paused, will retry ($e)');
      _retry ??= Timer(const Duration(seconds: 20), () {
        _retry = null;
        _flush();
      });
    } finally {
      _flushing = false;
    }
  }

  // -- Article metadata mapping ----------------------------------------------
  // LEGAL: metadata only — article bodies are never persisted client-side and
  // never rendered in the app. Every story opens at the publisher.

  Future<void> _upsertArticle(Article a) {
    return _client.from('articles').upsert(_articleRow(a));
  }

  // Never includes `embedding`, so upserts leave existing vectors untouched.
  Map<String, dynamic> _articleRow(Article a) => {
        'id': a.id,
        'source': a.provider.name,
        'source_name': a.source,
        'category': a.category.name,
        'title': a.headline,
        'snippet': a.snippet,
        'image_url': a.imageUrl,
        'original_url': a.url,
        'author': a.author,
        'read_minutes': a.readMinutes,
        'source_icon_url': a.sourceIconUrl,
        'full_text_available': a.hasFullBody,
        'published_at': a.publishedAt?.toUtc().toIso8601String(),
      };

  Article? _articleFromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    if (id == null) return null;

    final provider =
        ArticleProvider.values.asNameMap()[row['source']] ?? ArticleProvider.mock;
    // Bundled stories are restored from the asset so full text works offline.
    if (provider == ArticleProvider.mock) {
      final mock = mockArticles.where((m) => m.id == id).firstOrNull;
      if (mock != null) return mock;
    }

    final category =
        Category.values.asNameMap()[row['category']] ?? Category.world;
    final sourceName = row['source_name'] as String? ?? '';
    final author = row['author'] as String? ?? '';
    return Article(
      id: id,
      headline: row['title'] as String? ?? '',
      source: sourceName,
      author: author.isNotEmpty ? author : (sourceName.isNotEmpty ? sourceName : 'Unknown'),
      category: category,
      imageUrl: row['image_url'] as String? ?? '',
      snippet: row['snippet'] as String? ?? '',
      url: row['original_url'] as String? ?? '',
      readMinutes: (row['read_minutes'] as num?)?.toInt() ?? 3,
      palette: paletteFor(category),
      publishedAt: DateTime.tryParse(row['published_at'] as String? ?? '')
          ?.toLocal(),
      provider: provider,
      hasFullBody: row['full_text_available'] as bool? ?? false,
      sourceIconUrl: row['source_icon_url'] as String? ?? '',
      // Server-generated (Phase 10); null on rows not yet summarised. The
      // feed RPC and the saves→articles(*) join both surface these.
      aiSummary: row['ai_summary'] as String?,
      aiSummaryHook: row['ai_summary_hook'] as String?,
    );
  }
}
