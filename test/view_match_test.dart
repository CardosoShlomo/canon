import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canon/canon.dart';

// ViewMatch.conds (the core of the generated context.on / context.current)
// subscribes to a condition's key and re-evaluates only when that key changes.
enum FeedKeys with QueryKeyBase { category }

enum V with ScreenNode<V> {
  feed;

  @override
  Widget get widget => const _Body();
}

class _Init implements InitialScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

// a minimal generated-style ViewCond
class _Eq implements ViewCond {
  const _Eq(this.key, this._v);
  @override
  final String key;
  final Object? _v;
  @override
  bool test(Object? a) => a == _v;
}

int _builds = 0;

class _Body extends StatelessWidget {
  const _Body();
  @override
  Widget build(BuildContext context) {
    _builds++;
    final hit = ViewMatch.conds(context, V.feed, const [_Eq('category', 'books')]);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(hit ? 'match' : 'no-match'),
    );
  }
}

void main() {
  testWidgets('ViewMatch.conds re-evaluates reactively on its key', (tester) async {
    final graph = NavGraph(
      {
        V.feed().query({FeedKeys.category(Codec.string)})
      },
      seedChain: const _Init([(V.feed, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    expect(find.text('no-match'), findsOneWidget); // unset ≠ 'books'

    graph.viewSet(V.feed, 'category', 'books');
    await tester.pump();
    expect(find.text('match'), findsOneWidget); // now holds

    final before = _builds;
    graph.viewSet(V.feed, 'category', 'clothes');
    await tester.pump();
    expect(find.text('no-match'), findsOneWidget);
    expect(_builds, greaterThan(before)); // rebuilt on the watched key
  });
}
