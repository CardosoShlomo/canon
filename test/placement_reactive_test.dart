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
    final homeTop = Placement.isCurrent(context, V.home); // home is the foreground?
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text('${onDetail ? 'detail-on' : 'detail-off'}/'
          '${homeTop ? 'home-top' : 'home-buried'}'),
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
    expect(find.text('detail-off/home-top'), findsOneWidget); // home is the top
    expect(_homeBuilds, 1);

    graph.go(V.detail);
    await tester.pump();
    // detail entered the chain AND became the top → home is now buried
    expect(find.text('detail-on/home-buried'), findsOneWidget);
    expect(_homeBuilds, 2); // exactly one rebuild for the two-aspect flip

    graph.pop(); // back to home → detail leaves, home is top again
    await tester.pump();
    expect(find.text('detail-off/home-top'), findsOneWidget);
    expect(_homeBuilds, 3); // exactly one rebuild per status change — never more
  });
}
