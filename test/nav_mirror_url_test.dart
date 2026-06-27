import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// The in-session nav-mirror URL: derive it from the active stack, parse it back.
enum U with ScreenNode<U> {
  home,
  account;

  @override
  Widget get widget => const SizedBox.shrink();

  @override
  Codec<Object?>? get id => this == account ? Codec.string : null;
}

class _Init implements RootScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

NavGraph _mk() => NavGraph(
      {
        U.home({U.account()})
      },
      seedChain: const _Init([(U.home, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

void main() {
  test('derives the nav-mirror URL from the active stack', () async {
    final g = _mk();
    g.go(U.account, 'x');
    await Future<void>.delayed(Duration.zero);
    expect(g.currentUrl(), '/home/account/x');
  });

  test('applyUrl reconstructs the stack (round-trip)', () {
    final g = _mk();
    expect(g.applyUrl('/home/account/x'), isTrue);
    expect([for (final e in g.stack) e.screen], [U.home, U.account]);
    expect(g.stack.last.id, 'x');
    expect(g.currentUrl(), '/home/account/x');
  });

  test('truncates at the first unrepresentable segment', () {
    final g = _mk();
    expect(g.applyUrl('/home/nope/x'), isTrue); // home ok, nope unknown → truncate
    expect([for (final e in g.stack) e.screen], [U.home]);
  });
}
