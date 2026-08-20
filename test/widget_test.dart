import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/state/app_state.dart';

void main() {
  testWidgets('the app opens on the login gate', (tester) async {
    await tester.pumpWidget(BiteApp(state: AppState()));
    // Email is the hero and guest the secondary path. Both work.
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Continue as guest'), findsOneWidget);
    // Apple is ABSENT, not present-and-disabled. It used to render inert with
    // a "SOON" tag; App Store Review guideline 2.1 counts visible placeholder
    // controls as an incomplete app, so the option is gated on
    // AppConfig.appleSignInEnabled and appears only once it can complete.
    // This assertion is the guard: if someone reinstates a decorative button
    // on the front door, this fails.
    expect(find.text('Continue with Apple'), findsNothing);
    expect(find.text('SOON'), findsNothing);
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
