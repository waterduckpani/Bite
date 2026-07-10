import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../data/mock_articles.dart';
import '../models/article.dart';
import '../services/user_data_repository.dart';

/// Where the current article pool came from.
enum ContentStatus { loading, live, mock }

/// App state lives in memory and is the single source of truth for the UI;
/// a [UserDataRepository] (when configured) persists it to Supabase with
/// optimistic writes and hydrates it back at startup. Without one, behavior
/// is identical to the pre-persistence app.
class AppState extends ChangeNotifier {
  AppState({UserDataRepository? repository}) : _repo = repository;

  final UserDataRepository? _repo;

  bool onboarded = false;

  /// True while startup hydration from Supabase is in flight — the root
  /// widget holds off on choosing onboarding vs. home until this settles.
  bool hydrating = false;

  final Set<Category> selectedCategories = {};
  final Set<String> _dismissedIds = {};

  // Insertion-ordered so the Saved list shows newest saves first (reversed).
  final List<Article> _saved = [];

  /// The article pool backing every screen: mock data until (and unless) a
  /// live fetch succeeds.
  List<Article> _articles = mockArticles;
  ContentStatus status = ContentStatus.mock;

  /// Bumped whenever the feed deck must be rebuilt from scratch
  /// (category changes, feed reset, content arrival) — the swiper's key.
  int deckEpoch = 0;

  /// Restores onboarding, prefs, saves, and dismissals from Supabase. A
  /// no-op (and instant) when persistence is off or unreachable.
  Future<void> hydrate() async {
    final repo = _repo;
    if (repo == null || !repo.enabled) return;
    hydrating = true;
    notifyListeners();
    final data = await repo.hydrate();
    if (data != null) {
      onboarded = onboarded || data.onboarded;
      selectedCategories
        ..clear()
        ..addAll(data.categories);
      _saved
        ..clear()
        ..addAll(data.saved);
      _dismissedIds
        ..clear()
        ..addAll(data.dismissedIds);
    }
    hydrating = false;
    deckEpoch++;
    notifyListeners();
  }

  /// Loads the article pool. Since Phase 8 the deck is served from Supabase:
  /// a server-side cron ingests Guardian + NewsData and get_personalized_feed
  /// returns the ranked, unseen slice — the client never calls a news API,
  /// and no news-API key ships in the bundle. When Supabase is unreachable
  /// (or its pool is still empty) the deck falls back to mock data.
  Future<void> loadContent() async {
    if (!(_repo?.enabled ?? false)) return;
    status = ContentStatus.loading;
    notifyListeners();

    final ranked = await _repo!.fetchPersonalizedFeed();
    if (ranked != null && ranked.isNotEmpty) {
      _articles = ranked;
      _feedFetchedAt = DateTime.now();
      status = ContentStatus.live;
    } else {
      status = ContentStatus.mock;
    }
    deckEpoch++;
    notifyListeners();
  }

  /// Guardian body for the reader, proxied through the guardian-body Edge
  /// Function (and its server-side cache). Empty means the story has no
  /// readable body; throws when there's no backend or it's unreachable —
  /// the reader shows its open-in-browser fallback for both.
  Future<List<String>> fetchGuardianBody(String articleId) {
    final repo = _repo;
    if (repo == null || !repo.enabled) {
      return Future.error(StateError('no backend'));
    }
    return repo.fetchGuardianBody(articleId);
  }

  static const _minRefreshGap = Duration(seconds: 60);
  DateTime? _feedFetchedAt;
  bool _refreshing = false;

  /// Cheap mid-session refresh: re-queries the ranked deck from the database
  /// — no news-API calls involved, so a long session can refresh freely.
  /// Called when the deck runs low and from pull-to-refresh; throttled
  /// (unless [force], the explicit user gesture) so fast swiping can't spam
  /// the RPC.
  Future<void> refreshFeed({bool force = false}) async {
    final repo = _repo;
    if (repo == null || !repo.enabled || _refreshing) return;
    final last = _feedFetchedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _minRefreshGap) {
      return;
    }
    _refreshing = true;
    try {
      final ranked = await repo.fetchPersonalizedFeed();
      if (ranked == null || ranked.isEmpty) return;
      _feedFetchedAt = DateTime.now();
      // Only rebuild when the pool actually changed — a no-op refresh must
      // not reshuffle the cards under the user.
      if (listEquals(
          [for (final a in _articles) a.id], [for (final a in ranked) a.id])) {
        return;
      }
      _articles = ranked;
      status = ContentStatus.live;
      deckEpoch++;
      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  List<Article> get saved => List.unmodifiable(_saved.reversed);

  bool isSaved(Article a) => _saved.any((s) => s.id == a.id);

  int get dismissedCount => _dismissedIds.length;

  /// Articles still eligible for the swipe deck.
  List<Article> get deck => _articles
      .where((a) =>
          !_dismissedIds.contains(a.id) &&
          !isSaved(a) &&
          (selectedCategories.isEmpty ||
              selectedCategories.contains(a.category)))
      .toList();

  List<Article> articlesIn(Category c) =>
      _articles.where((a) => a.category == c).toList();

  /// [persist] is false for the dev skip-onboarding flag, so a dev boot
  /// never overwrites the real profile/prefs on the server.
  void completeOnboarding(Set<Category> picks, {bool persist = true}) {
    selectedCategories
      ..clear()
      ..addAll(picks);
    onboarded = true;
    if (persist) {
      _repo?.setOnboarded();
      _repo?.replaceCategoryPrefs(picks);
    }
    deckEpoch++;
    notifyListeners();
  }

  void toggleCategory(Category c) {
    selectedCategories.contains(c)
        ? selectedCategories.remove(c)
        : selectedCategories.add(c);
    _repo?.replaceCategoryPrefs(selectedCategories);
    deckEpoch++;
    notifyListeners();
  }

  // Swipes are the feed's gestures: they mutate state like the plain
  // methods below AND log implicit feedback to swipe_events.
  void swipeLeft(Article a) {
    _repo?.recordSwipe(a, 'left');
    dismiss(a);
  }

  void swipeRight(Article a) {
    _repo?.recordSwipe(a, 'right');
    save(a);
  }

  void swipeUp(Article a) => _repo?.recordSwipe(a, 'up');

  void dismiss(Article a) {
    _dismissedIds.add(a.id);
    notifyListeners();
  }

  void save(Article a) {
    if (!isSaved(a)) {
      _saved.add(a);
      _repo?.saveArticle(a);
      notifyListeners();
    }
  }

  void unsave(Article a) {
    _saved.removeWhere((s) => s.id == a.id);
    _repo?.removeSave(a.id);
    notifyListeners();
  }

  void toggleSaved(Article a) => isSaved(a) ? unsave(a) : save(a);

  /// Puts dismissed (not saved) articles back into the deck.
  void resetFeed() {
    _dismissedIds.clear();
    _repo?.recordFeedReset();
    deckEpoch++;
    notifyListeners();
  }

  // -- Auth ------------------------------------------------------------------

  /// Whether accounts exist at all — without Supabase the app is guest-only
  /// in-memory and every sign-in affordance is hidden.
  bool get hasAccounts => _repo?.enabled ?? false;

  /// The signed-in email, or null while browsing as a guest.
  String? get accountEmail => _repo?.accountEmail;

  bool get isSignedIn => accountEmail != null;

  Future<EmailOtpMode> sendSignInCode(String email) =>
      _repo!.sendEmailOtp(email);

  /// Verifies the emailed code. When it signed the device into a different
  /// existing account, local state is replaced by that account's data.
  Future<void> confirmSignInCode(
      String email, String code, EmailOtpMode mode) async {
    final switched = await _repo!.verifyEmailOtp(email, code, mode);
    if (switched) {
      _resetLocal();
      await hydrate();
    }
    notifyListeners();
  }

  /// Native Apple sign-in (dormant behind [AppConfig.appleSignInEnabled]).
  /// Mirrors [confirmSignInCode]: linking keeps the guest's data, switching
  /// to an existing account replaces it.
  Future<bool> signInWithApple() async {
    final switched = await _repo!.signInWithApple();
    if (switched) {
      _resetLocal();
      await hydrate();
    }
    notifyListeners();
    return switched;
  }

  /// Signs out into a fresh guest. Saves and history belong to the account
  /// and stay with it; topic picks are kept locally (and persisted to the
  /// new guest) so the feed doesn't jump back to onboarding.
  Future<void> signOut() async {
    await _repo!.signOut();
    _saved.clear();
    _dismissedIds.clear();
    _repo.setOnboarded();
    _repo.replaceCategoryPrefs(selectedCategories);
    deckEpoch++;
    notifyListeners();
  }

  void _resetLocal() {
    onboarded = false;
    selectedCategories.clear();
    _saved.clear();
    _dismissedIds.clear();
    deckEpoch++;
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
