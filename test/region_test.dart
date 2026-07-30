import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/models/region.dart';
import 'package:bite/state/app_state.dart';

import 'fake_webview_platform.dart';

/// Phase 16 region taxonomy.
///
/// The thing worth protecting here is not the widget layout — it is the
/// SEMANTICS the whole phase rests on: six regions, Global as the no-boost
/// default, the choice editable after onboarding, and a persisted value that
/// speaks the registry's vocabulary rather than a private enum name. Migrations
/// 0012, 0018 and 0019 each shipped a country signal that silently measured
/// nothing; the point of these tests is that the next such drift fails loudly.
void main() {
  setUpAll(FakeWebViewPlatform.install);

  test('the taxonomy is exactly the six selectable regions', () {
    expect(
      Region.values.map((r) => r.tag).toList(),
      ['GLOBAL', 'US', 'UK', 'EU', 'IN', 'AU'],
    );
    // Canada was a Phase 12 country with no Phase 16 region and no publisher to
    // boost. It maps to Global rather than erroring.
    expect(Region.fromTag('canada'), Region.global);
    // Phase 12 stored friendly enum names ('india'); Phase 16 stores registry
    // tags ('IN'). An old value must degrade to "no boost", never throw.
    expect(Region.fromTag('india'), Region.global);
    expect(Region.fromTag(null), Region.global);
    expect(Region.fromTag('IN'), Region.india);
  });

  test('Global is the default, so a fresh reader gets no boost', () {
    expect(AppState().region, Region.global);
    expect(Region.global.tag, 'GLOBAL');
  });

  testWidgets('onboarding offers all six regions and records the choice',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(BiteApp(state: state));

    for (final region in Region.values) {
      expect(find.text(region.label), findsOneWidget,
          reason: '${region.tag} missing from the onboarding selector');
    }

    await tester.tap(find.text('Tech'));
    await tester.pump();
    // The region pills sit below the topic pills in a scroll view.
    await tester.scrollUntilVisible(find.text('India'), 120);
    await tester.tap(find.text('India'));
    await tester.pump();
    await tester.tap(find.textContaining('Continue with 1'));
    await tester.pumpAndSettle();

    expect(state.region, Region.india);
  });

  testWidgets('region is editable after onboarding and preserves reading state',
      (tester) async {
    final state = AppState()..completeOnboarding({}, persist: false);
    state.markGestureTutorialSeen(persist: false);
    await tester.pumpWidget(BiteApp(state: state));
    await tester.pumpAndSettle();

    // Save a story and reject another, so there is state that a region change
    // must NOT disturb. Part E is a re-rank of the same pool, not a reset.
    final saved = state.deck.first;
    state.saveCard(saved);
    final rejected = state.deck.first;
    state.rejectCard(rejected);
    await tester.pumpAndSettle();
    final dismissedBefore = state.dismissedCount;

    await state.setRegion(Region.uk);
    await tester.pumpAndSettle();

    expect(state.region, Region.uk);
    expect(state.isSaved(saved), isTrue, reason: 'a save must survive');
    expect(state.dismissedCount, dismissedBefore,
        reason: 'swipe state must survive');
    expect(state.deck.any((a) => a.id == rejected.id), isFalse,
        reason: 'a rejected card must not come back');
  });

  testWidgets("profile's region selector renders and works in light and dark",
      (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      final state = AppState()..completeOnboarding({}, persist: false);
      state
        ..markGestureTutorialSeen(persist: false)
        ..setThemeMode(mode);
      await tester.pumpWidget(BiteApp(state: state));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(find.text('YOUR REGION'), findsOneWidget, reason: 'in $mode');

      for (final region in Region.values) {
        expect(find.text(region.label), findsOneWidget,
            reason: '${region.tag} missing from Profile in $mode');
      }

      // Editable from here, which is the half of the feature onboarding
      // cannot cover.
      final pill = find.text('Australia');
      await tester.ensureVisible(pill);
      await tester.pumpAndSettle();
      await tester.tap(pill, warnIfMissed: true);
      await tester.pumpAndSettle();
      expect(state.region, Region.australia, reason: 'in $mode');
    }
  });
}
