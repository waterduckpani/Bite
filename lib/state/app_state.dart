import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../config/feed_config.dart';
import '../data/mock_articles.dart';
import '../models/article.dart';
import '../models/country.dart';
import '../models/story_tracker.dart';
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

  /// Highest gesture-tutorial version this user has seen (0 = never). The
  /// coach-mark shows while this is below [FeedConfig.gestureTutorialVersion].
  int _seenTutorialVersion = 0;

  /// True while startup hydration from Supabase is in flight — the root
  /// widget holds off on choosing onboarding vs. home until this settles.
  bool hydrating = false;

  final Set<Category> selectedCategories = {};

  /// The user's country (Part E). [Country.global] applies no feed nudge.
  Country country = Country.global;
  // Rejected (swiped-left) cards — cleared by "reset feed", mirroring the
  // server's post-watermark dismissals.
  final Set<String> _dismissedIds = {};
  // Read (swiped-right) cards — a permanent local exclusion, NOT cleared by a
  // feed reset, mirroring the server RPC which excludes read stories forever.
  final Set<String> _readIds = {};
  // Cards the user has opened this session, so the "opened" positive signal is
  // logged at most once per card (repeated opens must not stack the boost).
  final Set<String> _openedIds = {};

  // Insertion-ordered so the Saved list shows newest saves first (reversed).
  final List<Article> _saved = [];

  /// Story trackers (Phase 13). Kept as a self-contained system: nothing here
  /// feeds back into the swipe deck, the taste vector, or feed ranking.
  final List<StoryTracker> _trackers = [];

  static const _uuid = Uuid();

  /// Max trackers per user, mirroring the server-side cap in create_tracker.
  static const int maxTrackers = 20;

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
      _seenTutorialVersion = data.seenTutorialVersion;
      selectedCategories
        ..clear()
        ..addAll(data.categories);
      _saved
        ..clear()
        ..addAll(data.saved);
      _dismissedIds
        ..clear()
        ..addAll(data.dismissedIds);
      _trackers
        ..clear()
        ..addAll(data.trackers);
      country = data.country;
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

  /// Articles still eligible for the swipe deck. Rejected, read, and saved
  /// cards all drop out; only rejects come back on a feed reset.
  List<Article> get deck => _articles
      .where((a) =>
          !_dismissedIds.contains(a.id) &&
          !_readIds.contains(a.id) &&
          !isSaved(a) &&
          (selectedCategories.isEmpty ||
              selectedCategories.contains(a.category)))
      .toList();

  List<Article> articlesIn(Category c) =>
      _articles.where((a) => a.category == c).toList();

  /// [persist] is false for the dev skip-onboarding flag, so a dev boot
  /// never overwrites the real profile/prefs on the server.
  void completeOnboarding(Set<Category> picks,
      {Country? country, bool persist = true}) {
    selectedCategories
      ..clear()
      ..addAll(picks);
    if (country != null) this.country = country;
    onboarded = true;
    if (persist) {
      _repo?.setOnboarded();
      _repo?.replaceCategoryPrefs(picks);
      if (country != null) _repo?.setCountry(country);
    }
    deckEpoch++;
    notifyListeners();
  }

  /// Updates the user's country (Part E) and lightly reweights the feed toward
  /// its coverage. A no-op nudge for [Country.global].
  void setCountry(Country value) {
    if (country == value) return;
    country = value;
    _repo?.setCountry(value);
    notifyListeners();
  }

  /// Whether the first-run gesture coach-mark should be shown: the user is
  /// past onboarding but hasn't seen the current gesture mapping explained.
  bool get shouldShowGestureTutorial =>
      onboarded && _seenTutorialVersion < FeedConfig.gestureTutorialVersion;

  /// Marks the current gesture tutorial as seen (persisted), so it won't
  /// re-show until [FeedConfig.gestureTutorialVersion] is bumped.
  void markGestureTutorialSeen() {
    if (_seenTutorialVersion >= FeedConfig.gestureTutorialVersion) return;
    _seenTutorialVersion = FeedConfig.gestureTutorialVersion;
    _repo?.setGestureTutorialSeen(FeedConfig.gestureTutorialVersion);
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

  // Phase 11 four-gesture model. Left/right/down each RESOLVE the current card
  // (dismiss + advance) with a distinct signal; up/tap is non-terminal — it
  // opens the reader and leaves the card for a later resolving swipe. Every
  // gesture mutates local state AND logs implicit feedback to swipe_events.

  /// Swipe left — "not interested". The only negative signal.
  void rejectCard(Article a) {
    _repo?.recordSwipe(a, 'reject');
    dismiss(a);
  }

  /// Swipe right — "read, done, moving on". A satisfied positive outcome;
  /// marks the card read (permanent local exclusion) and advances.
  void readCard(Article a) {
    _repo?.recordSwipe(a, 'read');
    _readIds.add(a.id);
    notifyListeners();
  }

  /// Swipe down — "save for later". Positive; adds to the saved list and
  /// advances.
  void saveCard(Article a) {
    _repo?.recordSwipe(a, 'save');
    save(a);
  }

  /// Swipe up OR tap — open the full story. Non-terminal, so no dismissal:
  /// the resolving swipe removes the card. Logs an additive "opened" boost at
  /// most once per card.
  void openCard(Article a) {
    if (_openedIds.add(a.id)) _repo?.recordSwipe(a, 'opened');
  }

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

  // -- Story trackers (Phase 13) ---------------------------------------------
  // A parallel system to the swipe feed. Follow state and unread counts read
  // straight off [_trackers]; the deck, taste vector, and ranking never see it.

  /// Trackers sorted by most recent activity (newest development first).
  List<StoryTracker> get trackers {
    final list = [..._trackers]..sort((a, b) => b.activityAt.compareTo(a.activityAt));
    return List.unmodifiable(list);
  }

  bool get hasTrackers => _trackers.isNotEmpty;

  /// Total unseen matched articles across all trackers — the Tracked tab badge.
  int get trackerUnreadCount =>
      _trackers.fold(0, (sum, t) => sum + t.unreadCount);

  /// Whether a tracker already exists for this article's story, so the card
  /// and reader can show a followed state and block a double-follow.
  bool isFollowing(String articleId) =>
      _trackers.any((t) => t.seedArticleId == articleId);

  StoryTracker? trackerById(String id) =>
      _trackers.where((t) => t.id == id).firstOrNull;

  /// Follows [article]'s story: optimistically adds a tracker seeded from it,
  /// then persists (the server copies the article's embedding + tags). No-op
  /// when already following it or at the [maxTrackers] cap.
  void followStory(Article article) {
    if (isFollowing(article.id) || _trackers.length >= maxTrackers) return;
    final id = _uuid.v4();
    final title = article.hasSummary ? article.aiSummaryHook! : article.headline;
    _trackers.add(StoryTracker(
      id: id,
      title: title,
      seedArticleId: article.id,
      createdAt: DateTime.now(),
    ));
    _repo?.createTracker(id, article, title);
    notifyListeners();
  }

  /// Re-queries the tracker list (counts + latest development) from the server.
  /// Called when the Tracked tab is opened and after a match refresh.
  Future<void> refreshTrackers() async {
    final repo = _repo;
    if (repo == null || !repo.enabled) return;
    final fresh = await repo.fetchTrackers();
    if (fresh == null) return;
    _trackers
      ..clear()
      ..addAll(fresh);
    notifyListeners();
  }

  /// The developing timeline for a tracker (newest match first).
  Future<List<Article>> trackerArticles(String trackerId) async {
    final repo = _repo;
    if (repo == null || !repo.enabled) return const [];
    return await repo.fetchTrackerArticles(trackerId) ?? const [];
  }

  /// Marks a tracker's articles seen on view — clears its unread count locally
  /// and on the server.
  void markTrackerViewed(String trackerId) {
    final i = _trackers.indexWhere((t) => t.id == trackerId);
    if (i == -1) return;
    if (_trackers[i].unreadCount == 0) return;
    _trackers[i] = _trackers[i].copyWith(unreadCount: 0);
    _repo?.markTrackerSeen(trackerId);
    notifyListeners();
  }

  void renameTracker(String trackerId, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final i = _trackers.indexWhere((t) => t.id == trackerId);
    if (i == -1) return;
    _trackers[i] = _trackers[i].copyWith(title: trimmed);
    _repo?.renameTracker(trackerId, trimmed);
    notifyListeners();
  }

  void setTrackerMuted(String trackerId, bool muted) {
    final i = _trackers.indexWhere((t) => t.id == trackerId);
    if (i == -1) return;
    _trackers[i] = _trackers[i].copyWith(muted: muted);
    _repo?.setTrackerMuted(trackerId, muted);
    notifyListeners();
  }

  void deleteTracker(String trackerId) {
    _trackers.removeWhere((t) => t.id == trackerId);
    _repo?.deleteTracker(trackerId);
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
    _readIds.clear();
    _openedIds.clear();
    _trackers.clear();
    _repo.setOnboarded();
    _repo.replaceCategoryPrefs(selectedCategories);
    _repo.setCountry(country);
    deckEpoch++;
    notifyListeners();
  }

  void _resetLocal() {
    onboarded = false;
    _seenTutorialVersion = 0;
    selectedCategories.clear();
    country = Country.global;
    _saved.clear();
    _dismissedIds.clear();
    _readIds.clear();
    _openedIds.clear();
    _trackers.clear();
    deckEpoch++;
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
