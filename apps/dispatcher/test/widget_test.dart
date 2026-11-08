// Widget smoke tests for the dispatcher app.
//
// The app now gates on role selection (AuthService.hasExplicitRole) and
// probes the backend on launch, so tests wrap DispatcherApp in its provider
// and expect the login gate — not the old single-screen lookup UI.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dispatcher/main.dart';
import 'package:dispatcher/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final auth = AuthService();
  await auth.initialize();
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthService>.value(
      value: auth,
      child: const DispatcherApp(baseUrl: 'http://127.0.0.1:1'),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('shows the role-selection gate on first run', (tester) async {
    await _pump(tester);
    expect(find.text('Select Your Role'), findsOneWidget);
    expect(find.text('Emergency Operations System'), findsOneWidget);
  });

  testWidgets('an unreachable API is reported in the status bar, not hidden',
      (tester) async {
    await _pump(tester);
    // The probe against 127.0.0.1:1 fails; the status line must say so.
    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining('unreachable'), findsWidgets);
  });

  testWidgets('selecting Dispatcher reveals name entry (gate is interactive)',
      (tester) async {
    await _pump(tester);
    await tester.scrollUntilVisible(find.text('Manage dispatches'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Manage dispatches'));
    await tester.pump();
    expect(find.text('Your Name *'), findsOneWidget);
  });
}
