import '../config/feed_config.dart';
import 'article.dart';

/// What the recommender has learned about a reader, reconstructed on the
/// client from their own swipe history so the Profile screen can show it back
/// to them.
///
/// This is a MIRROR, not the model. Ranking happens server-side against a
/// 384-dimension embedding centroid that can't be rendered as a list of
/// topics. What can be shown honestly is the input: which swipes went which
/// way, weighted exactly as get_personalized_feed weights them
/// ([FeedConfig.wRead] / [wSave] / [wOpen]), over the same
/// [FeedConfig.swipeWindow] of recent signals. Anything shown here should be
/// something the reader could verify by looking at what they swiped.
class TasteProfile {
  const TasteProfile({
    required this.reads,
    required this.saves,
    required this.opens,
    required this.rejects,
    required this.affinity,
    required this.rejected,
    required this.sources,
  });

  /// Counts of each gesture within the considered window.
  final int reads;
  final int saves;
  final int opens;
  final int rejects;

  /// Weighted positive pull per topic — the same weighting the server applies
  /// when it builds the taste centroid.
  final Map<Category, double> affinity;

  /// Reject counts per topic. Kept separate from [affinity] rather than
  /// subtracted from it: the server treats rejects as their own avoid
  /// centroid, and a topic can genuinely be both (you read a lot of World and
  /// still skip plenty of it).
  final Map<Category, int> rejected;

  /// Positive engagement per outlet, most engaged first.
  final Map<String, int> sources;

  static const empty = TasteProfile(
    reads: 0,
    saves: 0,
    opens: 0,
    rejects: 0,
    affinity: {},
    rejected: {},
    sources: {},
  );

  int get positiveSignals => reads + saves + opens;
  int get totalSignals => positiveSignals + rejects;
  bool get isEmpty => totalSignals == 0;

  /// Below the server's cold-start floor the feed isn't personalised at all —
  /// it's ranked on topics and recency. Saying so is the difference between a
  /// screen that informs and one that flatters.
  bool get isLearning => positiveSignals < FeedConfig.coldStartMin;

  /// How many more positive signals until personalisation starts.
  int get signalsUntilPersonalised =>
      (FeedConfig.coldStartMin - positiveSignals).clamp(0, FeedConfig.coldStartMin);

  /// Topics by weighted pull, strongest first, each with its share of the
  /// total positive weight (0–1).
  List<({Category category, double share})> get rankedTopics {
    final total = affinity.values.fold(0.0, (sum, v) => sum + v);
    if (total <= 0) return const [];
    final entries = affinity.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in entries) (category: e.key, share: e.value / total),
    ];
  }

  /// Topics the reader rejects more often than they engage with them — what
  /// the avoid centroid is pulling the feed away from.
  List<Category> get avoidedTopics {
    final out = <Category>[];
    for (final e in rejected.entries) {
      if (e.value >= 2 && e.value > (affinity[e.key] ?? 0)) out.add(e.key);
    }
    out.sort((a, b) => rejected[b]!.compareTo(rejected[a]!));
    return out;
  }

  /// Topics with nothing to say yet: no positive signal, and not enough
  /// rejects to count as avoided.
  ///
  /// Shown explicitly rather than omitted. Between this, [rankedTopics] and
  /// [avoidedTopics] every category appears exactly once, so a topic missing
  /// from the list is never ambiguous between "you don't like it" and "the
  /// screen ran out of room".
  List<Category> get quietTopics {
    final avoided = avoidedTopics.toSet();
    return [
      for (final c in Category.values)
        if ((affinity[c] ?? 0) <= 0 && !avoided.contains(c)) c,
    ];
  }

  /// Outlets by positive engagement, strongest first.
  List<({String source, int count})> get rankedSources {
    final entries = sources.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in entries) (source: e.key, count: e.value)];
  }

  /// Builds the profile from `swipe_events` rows joined to their articles,
  /// newest first.
  ///
  /// Only the most recent [FeedConfig.swipeWindow] positive signals count,
  /// mirroring the server's window — an old burst of reading shouldn't be
  /// presented as current taste when the ranker has already forgotten it.
  /// Rejects get their own window for the same reason.
  static TasteProfile fromRows(List<Map<String, dynamic>> rows) {
    var reads = 0, saves = 0, opens = 0, rejects = 0;
    final affinity = <Category, double>{};
    final rejected = <Category, int>{};
    final sources = <String, int>{};
    var positivesSeen = 0, rejectsSeen = 0;

    for (final row in rows) {
      final direction = row['direction'] as String?;
      if (direction == null) continue;
      final article = row['articles'] as Map<String, dynamic>?;
      final category = Category.values.asNameMap()[article?['category']];
      final source = (article?['source_name'] as String?)?.trim();

      if (direction == 'reject') {
        if (rejectsSeen >= FeedConfig.swipeWindow) continue;
        rejectsSeen++;
        rejects++;
        if (category != null) {
          rejected[category] = (rejected[category] ?? 0) + 1;
        }
        continue;
      }

      final weight = switch (direction) {
        'read' => FeedConfig.wRead,
        'save' => FeedConfig.wSave,
        'opened' => FeedConfig.wOpen,
        _ => 0.0,
      };
      if (weight == 0) continue;
      if (positivesSeen >= FeedConfig.swipeWindow) continue;
      positivesSeen++;

      switch (direction) {
        case 'read':
          reads++;
        case 'save':
          saves++;
        case 'opened':
          opens++;
      }
      if (category != null) {
        affinity[category] = (affinity[category] ?? 0) + weight;
      }
      if (source != null && source.isNotEmpty) {
        sources[source] = (sources[source] ?? 0) + 1;
      }
    }

    return TasteProfile(
      reads: reads,
      saves: saves,
      opens: opens,
      rejects: rejects,
      affinity: affinity,
      rejected: rejected,
      sources: sources,
    );
  }
}
