import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/state/app_state.dart';

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

  // NOT covered here: the server half of deletion. AppState.deleteAccount
  // requires a live UserDataRepository to sign into, which a widget test has
  // no way to provide, and a test that pumped a null repository would assert
  // nothing about deletion while looking like it did. That half is verified by
  // the block at the foot of migration 0027 (run against a throwaway account)
  // and should be re-checked on TestFlight before submission.
}
