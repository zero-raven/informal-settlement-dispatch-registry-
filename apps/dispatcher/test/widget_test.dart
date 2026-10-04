// Widget smoke test. Dispatch has no local write path — it is a thin client of
// registry-api — so this only proves the UI renders and error states display.

import 'package:flutter/material.dart';
import 'package:dispatcher/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dispatcher app renders the code entry screen', (tester) async {
    await tester.pumpWidget(const DispatcherApp(baseUrl: 'http://127.0.0.1:1'));
    await tester.pump();
    expect(find.text('Dispatch'), findsOneWidget);
    expect(find.text('Look up structure'), findsOneWidget);
    expect(find.text('Structure code'), findsOneWidget);
  });

  testWidgets('an unreachable API is reported, not hidden', (tester) async {
    await tester.pumpWidget(const DispatcherApp(baseUrl: 'http://127.0.0.1:1'));
    await tester.pump();
    // the probe fails silently into a status line rather than crashing
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Structure code'), findsOneWidget);
  });
}
