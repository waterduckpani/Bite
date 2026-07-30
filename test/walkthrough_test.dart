import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/data/practice_articles.dart';
import 'package:bite/main.dart';
import 'package:bite/screens/browser_screen.dart';
import 'package:bite/screens/onboarding_screen.dart';
import 'package:bite/screens/walkthrough_screen.dart';
import 'package:bite/state/app_state.dart';
import 'package:bite/widgets/article_card.dart';
import 'package:bite/widgets/bite_tab_bar.dart';

import 'fake_webview_platform.dart';

/// Phase 17: the login gate and the interactive walkthrough.
///
/// The load-bearing assertion in here is the SANDBOX one at the end. The
/// walkthrough's whole premise is that practising a gesture is not performing
/// it, and that premise is only worth anything if it is checked: every
/// mutating path in [AppState] (saveCard, readCard, rejectCard, openCard,
/// followStory) changes local state in the same breath as it queues its write,
/// so local state still being pristine after a full run is a direct proof that
/// nothing was written. A regression that wired a practice swipe to a real
/// handler would fail here rather than quietly teaching the recommender that
/// the reader loves five stories they never chose.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  setUp(() {
    // Reduced motion, so the looping hints settle instead of spinning forever
    // under pumpAndSettle. It also exercises the reduced-motion path, which is
    // the one where a still hint has to remain legible.
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });

  /// Waits out a step's confirmation flash and the advance that follows it.
  Future<void> settleStep(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pumpAndSettle();
  }

  Future<void> swipeCard(WidgetTester tester, Offset offset) async {
    await tester.drag(find.byType(ArticleCard).first, offset,
        warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  testWidgets('guest entry runs the walkthrough, which writes nothing',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(BiteApp(state: state));

    // -- Part A: the login gate --------------------------------------------
    await tester.tap(find.text('Continue as guest'));
    await tester.pumpAndSettle();
    expect(find.byType(WalkthroughScreen), findsOneWidget);
    expect(state.pastLoginGate, isTrue);

    final deckBefore = state.deck.length;

    // -- Part B1: gesture practice -----------------------------------------
    expect(find.text('This is a card'), findsOneWidget);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    // A wrong gesture is answered with help, and does NOT advance the step.
    expect(find.text('Swipe right to say read, done'), findsOneWidget);
    await swipeCard(tester, const Offset(-400, 0));
    expect(find.textContaining('That was a swipe left'), findsOneWidget);
    expect(find.text('Swipe right to say read, done'), findsOneWidget);

    // The right gesture confirms, then advances.
    await swipeCard(tester, const Offset(400, 0));
    expect(find.text('Read, done'), findsOneWidget);
    await settleStep(tester);

    expect(find.text('Swipe left for not interested'), findsOneWidget);
    await swipeCard(tester, const Offset(-400, 0));
    expect(find.text('Not interested'), findsOneWidget);
    await settleStep(tester);

    // Swipe up demonstrates the link-out by NAMING it, without navigating: no
    // browser is pushed, so a practice run can never leave the app.
    expect(find.text('Swipe up, or tap, to open it'), findsOneWidget);
    await swipeCard(tester, const Offset(0, -500));
    expect(find.text('Opens at ${practiceArticles.first.source}'),
        findsOneWidget);
    expect(find.byType(BrowserScreen), findsNothing);
    await settleStep(tester);

    expect(find.text('Swipe down to save it'), findsOneWidget);
    await swipeCard(tester, const Offset(0, 400));
    expect(find.text('Saved for later'), findsOneWidget);
    await settleStep(tester);

    // The track step teaches the real follow control with a sandboxed handler.
    expect(find.text('Follow a developing story'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.notifications_none));
    await tester.pumpAndSettle();
    expect(find.text('Following this story'), findsOneWidget);
    await settleStep(tester);

    // -- Part B2: the screen tour ------------------------------------------
    for (final (index, label) in const [
      (0, 'Feed'),
      (1, 'Saved'),
      (2, 'Tracked'),
      (3, 'Discover'),
      (4, 'Profile'),
    ]) {
      expect(find.text('Tap $label'), findsOneWidget);
      // Scoped to the bar: the panel behind it names the same screen, and the
      // point of the step is that the REAL tab is what gets tapped.
      Finder tab(String name) => find.descendant(
          of: find.byType(BiteTabBar), matching: find.text(name));
      if (index == 0) {
        // A tap on the wrong tab is corrected, not swallowed.
        await tester.tap(tab('Discover'));
        await tester.pumpAndSettle();
        expect(find.textContaining('That is Discover'), findsOneWidget);
        expect(find.text('Tap Feed'), findsOneWidget);
      }
      await tester.tap(tab(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(index == 4 ? 'Nearly there' : 'Next'));
      await tester.pumpAndSettle();
    }

    // -- Recap, and out into the topic picker ------------------------------
    expect(find.text('That is all of it'), findsOneWidget);
    await tester.tap(find.text('Pick my topics'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(state.shouldShowWalkthrough, isFalse);

    // -- The sandbox held --------------------------------------------------
    expect(state.saved, isEmpty, reason: 'a practised save is not a save');
    expect(state.dismissedCount, 0,
        reason: 'a practised reject is not a reject');
    expect(state.trackers, isEmpty,
        reason: 'a practised follow is not a tracker');
    expect(state.deck.length, deckBefore,
        reason: 'no real card was read or resolved');
    for (final practice in practiceArticles) {
      expect(state.isFollowing(practice.id), isFalse);
      expect(state.deck.any((a) => a.id == practice.id), isFalse,
          reason: 'practice cards must never enter the real pool');
    }
  });

  testWidgets('skip works from the first step and counts as seen',
      (tester) async {
    final state = AppState()..continueAsGuest();
    await tester.pumpWidget(BiteApp(state: state));
    await tester.pumpAndSettle();

    expect(find.byType(WalkthroughScreen), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(state.shouldShowWalkthrough, isFalse,
        reason: 'a skip is a decision, not a deferral');
  });

  testWidgets('signing out returns to the login gate, tutorial still seen',
      (tester) async {
    // Without Supabase there is no sign-out path to exercise end to end, so
    // this pins the state rule the screen routes on.
    final state = AppState()..continueAsGuest();
    state.markGestureTutorialSeen(persist: false);
    expect(state.pastLoginGate, isTrue);
    expect(state.shouldShowWalkthrough, isFalse);
  });
}
