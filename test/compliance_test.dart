import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/state/app_state.dart';
import 'package:bite/widgets/ai_summary_tag.dart';
import 'package:bite/widgets/article_card.dart';

import 'fake_webview_platform.dart';

/// Guards for the App Store / privacy-law obligations that are easy to break
/// by accident and expensive to discover at review time.
///
/// These assert on *reachability in the UI*, not on the underlying plumbing,
/// because that is exactly what gets lost: `delete_account` can be perfectly
/// implemented server-side and still fail review if no screen links to it.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  Future<void> openProfile(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(BiteApp(state: state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
  }

  AppState guest() => AppState()
    ..continueAsGuest()
    ..completeOnboarding({}, persist: false)
    ..markGestureTutorialSeen(persist: false);

  testWidgets('Profile links to the privacy policy and terms', (tester) async {
    final state = guest();
    await openProfile(tester, state);

    // App Store Connect wants a privacy-policy URL as metadata, but GDPR
    // Arts. 13-14 and the DPDP Act expect the notice to be reachable where
    // the data is actually collected. Both links live at the foot of Profile.
    final privacy = find.text('Privacy');
    final terms = find.text('Terms');
    await tester.scrollUntilVisible(privacy, 120);
    await tester.pumpAndSettle();
    expect(privacy, findsOneWidget);
    expect(terms, findsOneWidget);
  });

  testWidgets('a guest is not offered account deletion', (tester) async {
    final state = guest();
    await openProfile(tester, state);
    // There is no account to delete: a guest is a local anonymous session.
    // Offering it would be alarming and would do nothing.
    expect(find.text('Delete account'), findsNothing);
    expect(state.isSignedIn, isFalse);
  });

  testWidgets('a card carrying an AI bite says so on its face', (tester) async {
    // EU AI Act Art. 50(4): AI-generated text published to inform the public
    // must be disclosed as such, and Bite has no human editorial review to
    // claim the exemption. Independently of the law, the card puts machine
    // text beside a publisher's name and lettermark, so without this the
    // reader reads a model's words as the publisher's.
    final state = guest();
    await tester.pumpWidget(BiteApp(state: state));
    await tester.pumpAndSettle();

    final article = state.deck.firstWhere((a) => a.hasSummary);
    expect(article.aiSummary, isNotNull);
    // The bite is on screen...
    expect(find.text(article.aiSummary!), findsWidgets);
    // ...and so is the disclosure.
    expect(find.byType(AiSummaryTag), findsWidgets);
  });

  testWidgets('the walkthrough tells the reader who wrote the summary',
      (tester) async {
    // A tag is a reminder for someone who already knows. The walkthrough is
    // where a reader is actually taught what a bite is, so the full fact lives
    // there — including that it can be wrong. It sits on the open-story step,
    // which is where the reader is being sent to the publisher anyway.
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(() => TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAccessibilityFeaturesTestValue());

    Future<void> settleStep() async {
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pumpAndSettle();
    }

    Future<void> swipe(Offset offset) async {
      await tester.drag(find.byType(ArticleCard).first, offset,
          warnIfMissed: false);
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(BiteApp(state: AppState()));
    await tester.tap(find.text('Continue as guest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    // Drive to the open-story step: right, then left.
    await swipe(const Offset(400, 0));
    await settleStep();
    await swipe(const Offset(-400, 0));
    await settleStep();

    expect(find.text('Swipe up, or tap, to open it'), findsOneWidget);
    expect(
      find.textContaining('written by AI'),
      findsOneWidget,
      reason: 'the open-story step must name the summary as AI-written',
    );
  });

  // NOT covered here: the server half of deletion. AppState.deleteAccount
  // requires a live UserDataRepository to sign into, which a widget test has
  // no way to provide, and a test that pumped a null repository would assert
  // nothing about deletion while looking like it did. That half is verified by
  // the block at the foot of migration 0027 (run against a throwaway account)
  // and should be re-checked on TestFlight before submission.
}
