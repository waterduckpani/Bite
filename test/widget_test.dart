import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/state/app_state.dart';

void main() {
  testWidgets('the app opens on the login gate', (tester) async {
    await tester.pumpWidget(BiteApp(state: AppState()));
    expect(find.text('Continue as guest'), findsOneWidget);
    // The account options are present and visibly inactive, not hidden and
    // not faked: the "SOON" tag is the whole promise of Phase 17 Part A.
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('SOON'), findsNWidgets(2));
  });

  testWidgets('onboarding shows topic picker', (tester) async {
    final state = AppState()..continueAsGuest();
    state.markGestureTutorialSeen(persist: false);
    await tester.pumpWidget(BiteApp(state: state));
    expect(find.text('Tech'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
  });
}
