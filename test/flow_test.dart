import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/screens/browser_screen.dart';
import 'package:bite/state/app_state.dart';
import 'package:bite/widgets/article_card.dart';

import 'fake_webview_platform.dart';

void main() {
  // Every story link-outs since Phase 15.1, so the deck's open path builds a
  // WebViewController. There is no platform implementation under
  // `flutter test`; this registers an inert one.
  setUpAll(FakeWebViewPlatform.install);

  testWidgets('onboarding → feed → swipe to save/dismiss → saved → link-out',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(BiteApp(state: state));

    // Onboarding: pick two topics and continue.
    await tester.tap(find.text('Tech'));
    await tester.pump();
    await tester.tap(find.text('World'));
    await tester.pump();
    await tester.tap(find.textContaining('Continue with 2'));
    await tester.pumpAndSettle();

    // Dismiss the first-run gesture coach-mark, which otherwise sits over the
    // deck and absorbs swipes.
    state.markGestureTutorialSeen();
    await tester.pumpAndSettle();

    // Feed shows a card stack filtered to the picked topics.
    expect(find.byType(ArticleCard), findsWidgets);
    final deckSize = state.deck.length;
    expect(state.deck.every((a) => ['Tech', 'World'].contains(a.category.label)),
        isTrue);

    // Phase 11 gesture model: swipe DOWN → saves the top card.
    final topCard = state.deck.first;
    await tester.drag(find.byType(ArticleCard).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(state.isSaved(topCard), isTrue);

    // Swipe left → dismisses (rejects) the next card.
    final second = state.deck.first;
    await tester.drag(find.byType(ArticleCard).first, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(state.isSaved(second), isFalse);
    expect(state.deck.length, deckSize - 2);

    // Swipe up → link-outs to the publisher and keeps the card in the deck.
    // Phase 15.1: there is no native reader, so this is the ONLY open path.
    final third = state.deck.first;
    await tester.drag(find.byType(ArticleCard).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserScreen), findsOneWidget);
    expect(find.text(third.headline), findsWidgets);
    await tester.tap(find.byIcon(Icons.arrow_back).last);
    await tester.pumpAndSettle();
    expect(state.deck.first.id, third.id);

    // Saved tab lists the saved story; search filters it.
    await tester.tap(find.text('Saved'));
    await tester.pumpAndSettle();
    expect(find.text(topCard.headline), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zzz-no-match');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // Swipe-to-remove takes it out of Saved.
    await tester.drag(find.text(topCard.headline), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(state.saved, isEmpty);
    expect(find.text('Nothing saved yet'), findsOneWidget);
  });
}
