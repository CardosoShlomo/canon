import 'package:canon/canon.dart';
import 'package:test/test.dart';

enum P with ScreenNodeBase<P, Object> {
  home,
  product,
  review;

  @override
  Object get widget => name;

  @override
  Codec<Object?>? get id => switch (this) {
    product => Codec.string,
    _ => null,
  };
}

NavGraph _shop() => NavGraph({
  P.home({
    P.product({P.review}),
  }),
});

Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Hangs a page on every live slot, as the host does when it builds them.
void _host(NavGraph g) {
  for (final s in g.activeScope.slots) {
    s.page ??= Object();
  }
}

void main() {
  test('a system pop is announced like a folded one', () async {
    final g = _shop();
    g.go(P.home);
    g.go(P.product, 'a');
    await _settle();
    _host(g);
    final heard = <(Enum, Enum)>[];
    final sync = <(Enum, Enum)>[];
    final seen = <List<(Enum, Object?)>>[];
    g.navigations.listen((n) {
      heard.add((n.source.$1, n.destination.$1));
      seen.add(n.to);
    });
    g.observe((from, to) => sync.add((from, to)));
    g.onPageRemoved(g.activeScope.slots.last.page!);
    await _settle();
    expect(g.current, P.home);
    expect(sync, [(P.product, P.home)]);
    expect(heard, [(P.product, P.home)]);
    expect(seen.single.map((e) => e.$1), [P.home]);
  });

  test(
    'a page the host drops after a folded pop is not announced twice',
    () async {
      final g = _shop();
      g.go(P.home);
      g.go(P.product, 'a');
      await _settle();
      _host(g);
      final page = g.activeScope.slots.last.page!;
      var heard = 0;
      g.navigations.listen((_) => heard++);
      g.pop();
      await _settle();
      g.onPageRemoved(page);
      await _settle();
      expect(g.current, P.home);
      expect(heard, 1);
    },
  );
}
