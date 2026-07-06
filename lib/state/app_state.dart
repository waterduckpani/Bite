import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../data/mock_articles.dart';
import '../models/article.dart';
import '../services/content_service.dart';

/// Where the current article pool came from.
enum ContentStatus { loading, live, mock }

/// App state is in-memory: nothing is persisted yet (that's Phase 3).
class AppState extends ChangeNotifier {
  bool onboarded = false;

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

  /// Pulls live articles when keys are configured; keeps mock data
  /// otherwise or when every source fails.
  Future<void> loadContent({ContentService? service}) async {
    if (!AppConfig.hasLiveContent) return;
    status = ContentStatus.loading;
    notifyListeners();

    List<Article> live = const [];
    try {
      live = await (service ?? ContentService()).fetch();
    } catch (_) {}

    if (live.isNotEmpty) {
      _articles = live;
      status = ContentStatus.live;
    } else {
      status = ContentStatus.mock;
    }
    deckEpoch++;
    notifyListeners();
  }

  List<Article> get saved => List.unmodifiable(_saved.reversed);

  bool isSaved(Article a) => _saved.any((s) => s.id == a.id);

  int get dismissedCount => _dismissedIds.length;

  /// Articles still eligible for the swipe deck.
  List<Article> get deck => _articles
      .where((a) =>
          !_dismissedIds.contains(a.id) &&
          !isSaved(a) &&
          (selectedCategories.isEmpty || selectedCategories.contains(a.category)))
      .toList();

  List<Article> articlesIn(Category c) =>
      _articles.where((a) => a.category == c).toList();

  void completeOnboarding(Set<Category> picks) {
    selectedCategories
      ..clear()
      ..addAll(picks);
    onboarded = true;
    deckEpoch++;
    notifyListeners();
  }

  void toggleCategory(Category c) {
    selectedCategories.contains(c)
        ? selectedCategories.remove(c)
        : selectedCategories.add(c);
    deckEpoch++;
    notifyListeners();
  }

  void dismiss(Article a) {
    _dismissedIds.add(a.id);
    notifyListeners();
  }

  void save(Article a) {
    if (!isSaved(a)) {
      _saved.add(a);
      notifyListeners();
    }
  }

  void unsave(Article a) {
    _saved.removeWhere((s) => s.id == a.id);
    notifyListeners();
  }

  void toggleSaved(Article a) => isSaved(a) ? unsave(a) : save(a);

  /// Puts dismissed (not saved) articles back into the deck.
  void resetFeed() {
    _dismissedIds.clear();
    deckEpoch++;
    notifyListeners();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
