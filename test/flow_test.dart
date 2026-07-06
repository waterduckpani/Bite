import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/screens/reader_screen.dart';
import 'package:bite/state/app_state.dart';
import 'package:bite/widgets/article_card.dart';

void main() {
  testWidgets('onboarding → feed → swipe to save/dismiss → saved → reader',
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

    // Feed shows a card stack filtered to the picked topics.
    expect(find.byType(ArticleCard), findsWidgets);
    final deckSize = state.deck.length;
    expect(state.deck.every((a) => ['Tech', 'World'].contains(a.category.label)),
        isTrue);

    // Swipe right → saves the top card.
    final topCard = state.deck.first;
    await tester.drag(find.byType(ArticleCard).first, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(state.isSaved(topCard), isTrue);

    // Swipe left → dismisses the next card.
    final second = state.deck.first;
    await tester.drag(find.byType(ArticleCard).first, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(state.isSaved(second), isFalse);
    expect(state.deck.length, deckSize - 2);

    // Swipe up → opens the reader and keeps the card in the deck.
    final third = state.deck.first;
    await tester.drag(find.byType(ArticleCard).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
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
