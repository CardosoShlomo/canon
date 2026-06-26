import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

enum T with ScreenNode<T> { a, b; @override Widget get widget => const SizedBox.shrink(); }
class _Init implements InitialScreenBase { const _Init(this.chain); @override final List<(Enum, Object?)> chain; }
NavGraph _mk() => NavGraph({ T.a({ T.b({T.a.stacked}) }) }, seedChain: const _Init([(T.a, null)]), pageOf: (w,c,k)=>MaterialPage(child:w));

void main() {
  test('a({b({a.stacked})}) URL follows the rule', () async {
    final g = _mk();
    expect(g.currentUrl(), '/a');
    g.go(T.b); await Future<void>.delayed(Duration.zero);
    expect(g.currentUrl(), '/a/b');
    g.go(T.a); await Future<void>.delayed(Duration.zero);  // a.stacked → push
    expect([for (final e in g.stack) e.screen.name], ['a','b','a']); // blob has depth 3
    expect(g.currentUrl(), '/a');                                     // URL is top-only
  });
}
