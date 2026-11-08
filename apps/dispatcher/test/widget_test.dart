// Widget smoke tests for the unified app.
//
// The app gates on authentication (AuthService.hasExplicitRole) and probes
// the backend on launch, so tests wrap DispatcherApp in its provider and
// expect the credential login gate.
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
  testWidgets('shows the sign-in gate on first run', (tester) async {
    await _pump(tester);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Emergency Operations System'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
  });

  testWidgets('an unreachable API is reported in the status bar, not hidden',
      (tester) async {
    await _pump(tester);
    // The probe against 127.0.0.1:1 fails; the status line must say so.
    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining('unreachable'), findsWidgets);
  });

  testWidgets('empty credentials show an inline error, not a crash',
      (tester) async {
    await _pump(tester);
    await tester.scrollUntilVisible(find.text('Continue'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.text('Enter your username and password.'), findsOneWidget);
  });
}
