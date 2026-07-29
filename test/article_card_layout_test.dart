import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/data/palettes.dart';
import 'package:bite/models/article.dart';
import 'package:bite/state/app_state.dart';
import 'package:bite/theme/app_theme.dart';
import 'package:bite/widgets/article_card.dart';
import 'package:bite/widgets/cover_art.dart';
import 'package:bite/widgets/reader_cue.dart';

/// Phase 15.2: the bite IS the card, and the card does not scroll. These tests
/// pin the two ends of the bite-length range against the real deck geometry —
/// the summariser's 80-word ceiling must render in full, and a short bite must
/// not push the layout around.
void main() {
  // The default test font draws every glyph as a full em square, which makes
  // body copy roughly twice as wide as it really is — useless for a test about
  // whether text fits. Load the real bundled Inter so the metrics are the ones
  // the device uses.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader('Inter')
          ..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf')))
        .load();
  });

  // The deck's REAL box on an iPhone 17, measured from the running app — the
  // screen less the floating header, the tab bar and the swiper's own insets.
  // Guessing this from the screen size overstates it by ~70pt and hides
  // exactly the clipping these tests exist to catch.
  const cardSize = Size(360.5, 520.5);

  // 80 words — the summariser's ceiling.
  const longBite =
      'Planners in three of the largest delta cities now reissue elevation '
      'charts every quarter instead of every decade, because the ground moves '
      'faster than the paperwork behind it. The revisions have already pushed '
      'thousands of properties into flood categories carrying higher insurance '
      'costs and stricter building rules. City engineers say the quarterly '
      'cycle is not a temporary measure but the new baseline, and neighbouring '
      'authorities are preparing to adopt the same schedule within the year.';

  // ~40 words — the description-only stories, whose bites run short.
  const shortBite =
      'Regulators have opened an inquiry after four operators reported faults '
      'on the same undersea route within a day, disrupting international '
      'traffic for several hours. The operators said repairs are under way.';

  Article article({required String summary, required bool withImage}) => Article(
        id: 'test-1',
        headline: 'The publisher headline, which the card no longer leads with',
        source: 'The Christian Science Monitor',
        author: 'A Reporter',
        category: Category.world,
        imageUrl: withImage ? 'https://example.com/cover.jpg' : '',
        snippet: 'A raw publisher description that must never reach the card.',
        timeAgo: '3h ago',
        url: 'https://example.com/story',
        readMinutes: 4,
        palette: navyPalette,
        provider: ArticleProvider.rss,
        aiSummaryHook: 'Delta cities are redrawing their maps every quarter',
        aiSummary: summary,
      );

  Future<void> pumpCard(WidgetTester tester, Article a,
      {Brightness brightness = Brightness.light}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildBiteTheme(brightness),
        home: AppScope(
          state: AppState(),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: cardSize.width,
                height: cardSize.height,
                child: ArticleCard(article: a),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The rendered summary paragraph.
  RenderParagraph summaryOf(WidgetTester tester, String bite) =>
      tester.renderObject<RenderParagraph>(find.text(bite));

  for (final withImage in [true, false]) {
    final label = withImage ? 'with an image' : 'with no image';

    testWidgets('80-word bite renders in full $label', (tester) async {
      final a = article(summary: longBite, withImage: withImage);
      await pumpCard(tester, a);

      // The whole bite is shown — not truncated to fit.
      expect(summaryOf(tester, longBite).didExceedMaxLines, isFalse,
          reason: 'the 80-word ceiling must fit the card, not ellipsise');

      // And the link-out cue is still on the card, not pushed off the bottom.
      final card = tester.getRect(find.byType(ArticleCard));
      final cue = tester.getRect(find.byType(LinkOutCue));
      expect(cue.bottom, lessThanOrEqualTo(card.bottom));
      expect(cue.top, greaterThanOrEqualTo(card.top));

      // Even squeezed by the longest bite, the cover stays a real band rather
      // than collapsing to a sliver.
      expect(tester.getRect(find.byType(CoverArt)).height,
          greaterThanOrEqualTo(100));

      // The hook leads and the raw publisher description never appears.
      expect(find.text(a.aiSummaryHook!), findsOneWidget);
      expect(find.text(a.snippet), findsNothing);
      expect(find.textContaining('read at ${a.source}'), findsOneWidget);
      expect(find.text(a.source), findsOneWidget);
    });

    testWidgets('40-word bite gives its slack to the cover $label',
        (tester) async {
      await pumpCard(tester, article(summary: shortBite, withImage: withImage));
      expect(summaryOf(tester, shortBite).didExceedMaxLines, isFalse);
      final shortCard = tester.getRect(find.byType(ArticleCard));
      final shortCover = tester.getRect(find.byType(CoverArt));
      final shortCueGap =
          shortCard.bottom - tester.getRect(find.byType(LinkOutCue)).top;

      await pumpCard(tester, article(summary: longBite, withImage: withImage));
      final longCard = tester.getRect(find.byType(ArticleCard));
      final longCover = tester.getRect(find.byType(CoverArt));
      final longCueGap =
          longCard.bottom - tester.getRect(find.byType(LinkOutCue)).top;

      // The COVER absorbs the difference — a short bite means a taller cover,
      // not a dead gap in the text block.
      expect(shortCover.height, greaterThan(longCover.height),
          reason: 'the cover, not a gap, should take up the slack');

      // And because the text block is bottom-anchored, the cue and attribution
      // sit in exactly the same place whatever the bite length.
      expect(shortCueGap, closeTo(longCueGap, 0.01));
      expect(shortCueGap, lessThan(shortCard.height));
    });
  }

  // A live Deutsche Welle hook that clipped mid-word ("humanoid rob…") when
  // the hook was capped at two lines, under a mostly empty cover.
  testWidgets('a long hook takes a third line rather than clipping',
      (tester) async {
    const longHook =
        'The US has banned imports of foreign-made humanoid robots';
    final a = Article(
      id: 'test-2',
      headline: 'Publisher headline',
      source: 'Deutsche Welle',
      author: 'DW',
      category: Category.world,
      imageUrl: '',
      snippet: 'raw description',
      timeAgo: '31m ago',
      url: 'https://example.com/story',
      readMinutes: 2,
      palette: navyPalette,
      provider: ArticleProvider.rss,
      aiSummaryHook: longHook,
      aiSummary: shortBite,
    );
    await pumpCard(tester, a);

    expect(
        tester.renderObject<RenderParagraph>(find.text(longHook))
            .didExceedMaxLines,
        isFalse,
        reason: 'a hook with room above it must not clip mid-word');
    expect(summaryOf(tester, shortBite).didExceedMaxLines, isFalse);
  });

  testWidgets('card lays out in dark mode without overflow', (tester) async {
    await pumpCard(tester, article(summary: longBite, withImage: true),
        brightness: Brightness.dark);
    expect(tester.takeException(), isNull);
  });
}
