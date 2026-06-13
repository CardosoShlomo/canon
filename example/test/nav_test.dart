import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canon_example/nav.dart';

void main() {
  testWidgets('grammar validates, renders, and navigates', (tester) async {
    verifyScreens();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: Screen.delegate));
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'splash');

    Screen.goHome();
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'home');

    Screen.goItem('42');
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'item');

    expect(Screen.maybePop(), isTrue); // back to home
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'home');
  });
}
