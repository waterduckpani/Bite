import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../config/feed_config.dart';
import '../data/mock_articles.dart';
import '../models/article.dart';
import '../models/region.dart';
import '../models/story_tracker.dart';
import '../models/taste_profile.dart';
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

  /// Whether the user has come through the Phase 17 login screen in this
  /// session (as a guest, or by signing in).
  ///
  /// Deliberately NOT a new persisted column. An onboarded profile can only
  /// exist on the far side of the gate, so hydration derives it from
  /// `onboarded` instead: one less thing to migrate, and nothing to go stale.
  /// Signing out clears it, which is what puts a logged-out user back on the
  /// login screen rather than silently into a fresh guest deck.
  bool _passedLoginGate = false;

  bool get pastLoginGate => _passedLoginGate;

  /// "Continue as guest": the anonymous session is created lazily by the
  /// repository on the first write/read, so this only has to open the gate.
  void continueAsGuest() {
    if (_passedLoginGate) return;
    _passedLoginGate = true;
    notifyListeners();
  }

  /// Highest gesture-tutorial version this user has seen (0 = never). The
  /// walkthrough runs while this is below
  /// [FeedConfig.gestureTutorialVersion].
  int _seenTutorialVersion = 0;

  /// True while startup hydration from Supabase is in flight — the root
  /// widget holds off on choosing onboarding vs. home until this settles.
  bool hydrating = false;

  final Set<Category> selectedCategories = {};

  /// The user's region (Phase 16). [Region.global] applies no feed boost.
  Region region = Region.global;

  /// TEMPORARY (dev): appearance override for testing light/dark in-app.
  /// In-memory only — never persisted, so every launch starts on `system`.
  ThemeMode themeMode = ThemeMode.system;

  void setThemeMode(ThemeMode mode) {
    if (themeMode == mode) return;
    themeMode = mode;
    notifyListeners();
  }

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

  /// When each save happened, keyed by article id. Hydrated from `saves.
  /// saved_at`; locally-saved rows are stamped at save time. The Saved
  /// screen's date sorting reads this rather than list order, which a
  /// hydration landing mid-session would otherwise scramble.
  final Map<String, DateTime> _savedAt = {};

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
      // A returning user with a profile has already chosen guest-or-sign-in
      // once; don't ask again on every launch.
      _passedLoginGate = _passedLoginGate || data.onboarded;
      // Never regress a local acknowledgement: hydration can land after the
      // user has already dismissed the coach-mark (or after the dev
      // skip-tutorial flag set it), and overwriting would pop it back up.
      _seenTutorialVersion =
          data.seenTutorialVersion > _seenTutorialVersion
              ? data.seenTutorialVersion
              : _seenTutorialVersion;
      selectedCategories
        ..clear()
        ..addAll(data.categories);
      _saved
        ..clear()
        ..addAll(data.saved);
      _savedAt
        ..clear()
        ..addAll(data.savedAt);
      _dismissedIds
        ..clear()
        ..addAll(data.dismissedIds);
      _trackers
        ..clear()
        ..addAll(data.trackers);
      region = data.region;
    }
    hydrating = false;
    deckEpoch++;
    notifyListeners();
  }

  /// Loads the article pool. Since Phase 8 the deck is served from Supabase:
  /// a server-side cron ingests publisher RSS and get_personalized_feed
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
      {Region? region, bool persist = true}) {
    selectedCategories
      ..clear()
      ..addAll(picks);
    if (region != null) this.region = region;
    onboarded = true;
    if (persist) {
      _repo?.setOnboarded();
      _repo?.replaceCategoryPrefs(picks);
      if (region != null) _repo?.setRegion(region);
    }
    deckEpoch++;
    notifyListeners();
  }

  /// True while a region change is re-querying the deck, so the selector can
  /// show that it is working rather than looking inert for a round trip.
  bool _switchingRegion = false;
  bool get switchingRegion => _switchingRegion;

  /// Updates the user's region and re-ranks the deck IN PLACE (Phase 16,
  /// Part E). No restart, no close-and-reopen.
  ///
  /// This is a RE-RANK of the same shared pool under a different additive
  /// boost, not a reset. Nothing here clears anything: the taste vector lives
  /// server-side and is rebuilt from swipe_events on every query, and the
  /// saved list, dismissed set and read set are all untouched — so bookmarks
  /// and swipe state survive the change and only the ORDER of the deck moves.
  ///
  /// The write is awaited before the re-query: the boost is applied
  /// server-side from profiles.region, so re-querying first would rank the new
  /// deck under the OLD region and the change would appear to do nothing.
  ///
  /// [refreshFeed] is forced deliberately. Its 60-second throttle exists to
  /// stop fast swiping spamming the RPC; a deliberate region change is the
  /// opposite of that — the user is watching, waiting for it to happen.
  Future<void> setRegion(Region value) async {
    if (region == value) return;
    region = value;
    _switchingRegion = true;
    notifyListeners();
    try {
      await _repo?.setRegion(value);
      await refreshFeed(force: true);
    } finally {
      _switchingRegion = false;
      notifyListeners();
    }
  }

  /// Whether the Phase 17 interactive walkthrough should run: the user is
  /// through the login gate but hasn't been taught the current gesture
  /// mapping.
  ///
  /// Gated on the LOGIN gate rather than on `onboarded`, because the
  /// walkthrough now runs BEFORE the interest/region picker: a reader is shown
  /// how the deck works before being asked what they want in it.
  bool get shouldShowWalkthrough =>
      _passedLoginGate &&
      _seenTutorialVersion < FeedConfig.gestureTutorialVersion;

  /// Marks the current walkthrough as seen (persisted), so it won't re-run
  /// until [FeedConfig.gestureTutorialVersion] is bumped. Completing and
  /// skipping both land here: a skip is a decision, not a deferral.
  ///
  /// [persist] is false for the dev skip-tutorial flag, so a dev boot never
  /// writes the acknowledgement to the real profile — same discipline as
  /// [completeOnboarding].
  void markGestureTutorialSeen({bool persist = true}) {
    if (_seenTutorialVersion >= FeedConfig.gestureTutorialVersion) return;
    _seenTutorialVersion = FeedConfig.gestureTutorialVersion;
    if (persist) {
      _repo?.setGestureTutorialSeen(FeedConfig.gestureTutorialVersion);
    }
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
    // Opening a story IS the referral — the reader is being handed to the
    // publisher's own page, which since Phase 15.1 is the only thing opening a
    // story can mean. recordReferral resolves the publisher server-side and
    // ignores rows that have none (legacy Guardian-API, mock), so this needs
    // no condition on the client.
    recordLinkOut(a);
  }

  // -- Referral instrumentation (Phase 14, Part F) ---------------------------
  // Impressions and link-outs feed the per-publisher CTR report — the number
  // that goes into a publisher email. Both are deduped per session so a card
  // returned to after an open can't inflate either count.

  final Set<String> _impressionIds = {};
  final Set<String> _linkOutIds = {};

  /// Logged when a card is ACTUALLY the top of the deck — not when it is built
  /// as the peeking back card, and not when the deck is prefetched. An inflated
  /// impression count would deflate CTR and make the referral claim look worse
  /// than it is; a missed one would flatter it. Both are wrong, so this fires
  /// exactly once per card per session.
  void recordImpression(Article a) {
    if (_impressionIds.add(a.id)) _repo?.recordReferral(a.id, 'impression');
  }

  void recordLinkOut(Article a) {
    if (_linkOutIds.add(a.id)) _repo?.recordReferral(a.id, 'linkout');
  }

  void dismiss(Article a) {
    _dismissedIds.add(a.id);
    notifyListeners();
  }

  void save(Article a) {
    if (!isSaved(a)) {
      _saved.add(a);
      _savedAt[a.id] = DateTime.now();
      _repo?.saveArticle(a);
      notifyListeners();
    }
  }

  void unsave(Article a) {
    _saved.removeWhere((s) => s.id == a.id);
    _savedAt.remove(a.id);
    _repo?.removeSave(a.id);
    notifyListeners();
  }

  /// When [articleId] was saved, or null for a save with no recorded time
  /// (a pre-existing row hydrated without one).
  DateTime? savedAtOf(String articleId) => _savedAt[articleId];

  /// Categories actually present in the Saved list — what the Saved screen
  /// offers as filters, so it never shows a chip that can only ever be empty.
  List<Category> get savedCategories {
    final present = {for (final a in _saved) a.category};
    return [for (final c in Category.values) if (present.contains(c)) c];
  }

  void toggleSaved(Article a) => isSaved(a) ? unsave(a) : save(a);

  /// Puts dismissed (not saved) articles back into the deck.
  void resetFeed() {
    _dismissedIds.clear();
    _repo?.recordFeedReset();
    deckEpoch++;
    notifyListeners();
  }

  // -- Taste profile (Profile screen) ----------------------------------------
  // A read-only mirror of the swipe history the server ranks from. Nothing
  // here feeds back into ranking — it exists so a reader can see what their
  // swipes have taught the feed.

  TasteProfile? _taste;
  bool _loadingTaste = false;

  /// The reader's reconstructed taste profile, or null before the first load.
  TasteProfile? get taste => _taste;

  bool get loadingTaste => _loadingTaste;

  /// Re-reads the swipe history and rebuilds the profile. Called when Profile
  /// is opened; safe to call repeatedly (concurrent calls collapse).
  Future<void> loadTasteProfile() async {
    final repo = _repo;
    if (repo == null || !repo.enabled || _loadingTaste) return;
    _loadingTaste = true;
    notifyListeners();
    final rows = await repo.fetchSwipeHistory();
    // A failed fetch leaves any previously-built profile in place rather than
    // blanking the section under the reader.
    if (rows != null) _taste = TasteProfile.fromRows(rows);
    _loadingTaste = false;
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

  /// The tracker seeded from [articleId], if this story is followed — what
  /// the reader's follow toggle unfollows.
  StoryTracker? trackerForArticle(String articleId) =>
      _trackers.where((t) => t.seedArticleId == articleId).firstOrNull;

  /// Unfollows the story seeded from [articleId]. Destructive (the timeline
  /// goes with the tracker), so callers confirm first.
  void unfollowStory(String articleId) {
    final tracker = trackerForArticle(articleId);
    if (tracker != null) deleteTracker(tracker.id);
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
    _passedLoginGate = true;
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
    _passedLoginGate = true;
    notifyListeners();
    return switched;
  }

  /// Signs out into a fresh guest. Saves and history belong to the account
  /// and stay with it; topic picks are kept locally (and persisted to the
  /// new guest) so the feed doesn't jump back to onboarding.
  Future<void> signOut() async {
    await _repo!.signOut();
    _saved.clear();
    _savedAt.clear();
    _dismissedIds.clear();
    _readIds.clear();
    _openedIds.clear();
    // A different user seeing the same card is a genuinely new impression.
    _impressionIds.clear();
    _linkOutIds.clear();
    _trackers.clear();
    // The taste profile describes the account that just signed out.
    _taste = null;
    _repo.setOnboarded();
    _repo.replaceCategoryPrefs(selectedCategories);
    // The walkthrough teaches the app, not the account: someone who has
    // already been through it must not sit through it again just because they
    // signed out. Carried onto the fresh guest profile alongside the topic and
    // region picks, for the same reason.
    if (_seenTutorialVersion > 0) {
      _repo.setGestureTutorialSeen(_seenTutorialVersion);
    }
    await _repo.setRegion(region);
    // Signing out means being logged out, and a logged-out user is shown the
    // login screen rather than dropped into an unexplained guest deck.
    _passedLoginGate = false;
    deckEpoch++;
    notifyListeners();
  }

  void _resetLocal() {
    onboarded = false;
    // Not the login gate: this runs when the device signs INTO an existing
    // account, which is itself passing the gate.
    _seenTutorialVersion = 0;
    selectedCategories.clear();
    region = Region.global;
    _saved.clear();
    _savedAt.clear();
    _dismissedIds.clear();
    _readIds.clear();
    _openedIds.clear();
    _impressionIds.clear();
    _linkOutIds.clear();
    _trackers.clear();
    _taste = null;
    deckEpoch++;
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
