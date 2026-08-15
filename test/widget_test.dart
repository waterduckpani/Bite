import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/state/app_state.dart';

void main() {
  testWidgets('the app opens on the login gate', (tester) async {
    await tester.pumpWidget(BiteApp(state: AppState()));
    // Email is the hero and guest the secondary path; Apple is the one option
    // still rendered visibly inactive, not hidden and not faked.
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Continue as guest'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('SOON'), findsOneWidget);
    // This build has no Supabase, so there is no account to sign into and the
    // hero is inert. On a configured build it opens the sign-in sheet.
    final hero = tester.widget<FilledButton>(
        find.ancestor(
            of: find.text('Continue with email'),
            matching: find.byType(FilledButton)));
    expect(hero.onPressed, isNull);
  });

  testWidgets('onboarding shows topic picker', (tester) async {
    final state = AppState()..continueAsGuest();
    state.markGestureTutorialSeen(persist: false);
    await tester.pumpWidget(BiteApp(state: state));
    expect(find.text('Tech'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
  });
}
