import 'package:flutter_test/flutter_test.dart';

import 'package:bite/main.dart';
import 'package:bite/state/app_state.dart';

void main() {
  testWidgets('onboarding shows topic picker', (tester) async {
    await tester.pumpWidget(BiteApp(state: AppState()));
    expect(find.text('Tech'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
  });
}
