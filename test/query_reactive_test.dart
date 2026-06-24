import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canon/canon.dart';

// Query.of(context, key) subscribes a widget to ONE view-state key — it rebuilds
// when that key is added/removed/changed, via InheritedModel aspects.
enum FeedKeys with QueryKeyBase { category, radius }

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

int _categoryBuilds = 0;

class _Body extends StatelessWidget {
  const _Body();
  @override
  Widget build(BuildContext context) {
    _categoryBuilds++;
    final category = Query.of<String>(context, FeedKeys.category);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(category ?? 'none'),
    );
  }
}

void main() {
  testWidgets('Query.of reads + rebuilds only when its key changes',
      (tester) async {
    final graph = NavGraph(
      {
        V.feed().query({
          FeedKeys.category(Codec.string),
          FeedKeys.radius(Codec.integer),
        }),
      },
      seedChain: const _Init([(V.feed, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    expect(find.text('none'), findsOneWidget);
    final atStart = _categoryBuilds;

    graph.viewSet(V.feed, 'category', 'books');
    await tester.pump();
    expect(find.text('books'), findsOneWidget);
    expect(_categoryBuilds, atStart + 1); // rebuilt once for the watched key

    // Changing an UNwatched key must not rebuild the category widget.
    final beforeRadius = _categoryBuilds;
    graph.viewSet(V.feed, 'radius', 7);
    await tester.pump();
    expect(_categoryBuilds, beforeRadius); // no rebuild
  });
}
