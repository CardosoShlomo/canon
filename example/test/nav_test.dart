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

    // `item` is a union (under home & feed) → no global verb; chain off the
    // home handle (we're on home) to reach the home placement.
    Screen.on(.home)!.goItem('42');
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'item');

    // inherit: editItem's id IS item's, so the push verb takes no id.
    Screen.on(.home.item('42'))!.goEditItem();
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'editItem');
    expect(Screen.stack.currentId, '42'); // inherited from item, not passed
    Screen.pop();
    await tester.pumpAndSettle();

    // parentOf: push editItem onto whatever scope is on top, without naming
    // item's placement. We're on item (an editItem parent) → resolves.
    Screen.on(.parentOf.editItem)?.go();
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'editItem');
    expect(Screen.stack.currentId, '42');

    expect(Screen.pop(), isNotNull); // typed global pop → back to item
    await tester.pumpAndSettle();
    expect(Screen.stack.current.name, 'item');
  });
}
