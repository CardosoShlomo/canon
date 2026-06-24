import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canon/canon.dart';

// Placement.isOn(context, screen) (the runtime behind Screen.of(context, …))
// rebuilds a widget only when that screen enters/leaves the active chain.
enum V with ScreenNode<V> {
  home,
  detail,
  other;

  @override
  Widget get widget => this == home ? const _Home() : const SizedBox.shrink();
}

class _Init implements InitialScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

int _homeBuilds = 0;

class _Home extends StatelessWidget {
  const _Home();
  @override
  Widget build(BuildContext context) {
    _homeBuilds++;
    final onDetail = Placement.isOn(context, V.detail);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(onDetail ? 'detail-on' : 'detail-off'),
    );
  }
}

void main() {
  testWidgets('Placement.isOn rebuilds only when its screen enters/leaves',
      (tester) async {
    final graph = NavGraph(
      {
        V.home({V.detail(), V.other()})
      },
      seedChain: const _Init([(V.home, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    expect(find.text('detail-off'), findsOneWidget);

    graph.go(V.detail);
    await tester.pump();
    expect(find.text('detail-on'), findsOneWidget); // detail entered the chain

    graph.pop(); // back to home → detail leaves the chain
    await tester.pump();
    expect(find.text('detail-off'), findsOneWidget);
  });
}
