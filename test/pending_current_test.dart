import 'package:canon/canon.dart';
import 'package:test/test.dart';

// Help sits in two places, so its placement is read from the live path.
enum P with ScreenNodeBase<P, Object> {
  home,
  product,
  help;

  @override
  Object get widget => name;

  @override
  Codec<Object?>? get id => product == this ? Codec.string : null;
}

void main() {
  // A go not yet committed (a link arriving while a screen is up) is what the
  // next read sees: the top screen and its path agree, so a screen placed in
  // several spots is never looked up on a path that does not hold it.
  test('the current screen and its path agree while a go is pending', () async {
    final g = NavGraph({
      P.home({
        P.product({P.help}),
        P.help,
      }),
    });
    g.go(P.home);
    g.go(P.help);
    await Future<void>.delayed(Duration.zero);
    expect(g.current, P.help);

    g.go(P.product, 'a');
    expect(g.currentChain.last, P.product);
    expect(g.current, P.product);
    await Future<void>.delayed(Duration.zero);
    expect(g.current, P.product);
  });

  // Help sits under home and under product; only the one under home reaches
  // product, so the same screen answers by where it stands.
  test('a screen placed twice reaches only what its own placement holds', () async {
    final g = NavGraph({
      P.home({
        P.product({P.help}),
        P.help({P.product}),
      }),
    });
    g.go(P.home);
    g.go(P.help);
    await Future<void>.delayed(Duration.zero);
    expect(g.reaches(P.product), isTrue);
    g.go(P.product, 'a');
    g.go(P.help);
    await Future<void>.delayed(Duration.zero);
    expect(g.current, P.help);
    expect(g.reaches(P.product), isFalse);
  });
}
