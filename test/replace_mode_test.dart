import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// markReplace() flips the next commit to CommitMode.replace; a missed redirect
// chain (markReplace with no following commit) must NOT leak into a later nav.
enum R with ScreenNode<R> {
  home,
  feed;

  @override
  Widget get widget => const SizedBox.shrink();
}

class _Init implements RootScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

NavGraph _graph() => NavGraph(
      {R.home(), R.feed()},
      seedChain: const _Init([(R.home, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

void main() {
  test('markReplace makes the next commit a replace', () async {
    final graph = _graph();
    final modes = <CommitMode>[];
    graph.navigations.listen((n) => modes.add(n.mode));

    graph.markReplace();
    graph.go(R.feed);
    await Future<void>.delayed(Duration.zero);

    expect(modes, [CommitMode.replace]);
  });

  test('a missed redirect (no commit) drops the flag — later nav stays push',
      () async {
    final graph = _graph();
    final modes = <CommitMode>[];
    graph.navigations.listen((n) => modes.add(n.mode));

    graph.markReplace(); // e.g. `Screen.replace.on(.x)?` that returned null
    await Future<void>.delayed(Duration.zero); // the drop microtask runs
    graph.go(R.feed); // an unrelated, later navigation
    await Future<void>.delayed(Duration.zero);

    expect(modes, [CommitMode.push]);
  });
}
