import 'package:canon/canon.dart';
import 'package:test/test.dart';

// A shop: products on the home tab, each with reviews; a product's id is a
// non-empty string, so an empty one has no token.
enum P with ScreenNodeBase<P, Object> {
  home,
  product,
  review,
  about;

  @override
  Object get widget => name;

  @override
  Codec<Object?>? get id => switch (this) {
        product => Codec.string,
        review => Codec.integer,
        _ => null,
      };
}

NavGraph _shop() => NavGraph({
      P.home({
        P.product({
          P.review({P.about}),
          P.about,
        }),
      }),
    });

Future<void> _settle() => Future<void>.delayed(Duration.zero);

List<(Enum, Object?)> _stack(NavGraph g) =>
    [for (final e in g.stack) (e.screen, e.id)];

void main() {
  group('a broken percent escape never throws', () {
    const bad = [
      'https://shop.example/home/product/%E0%A4',
      'https://shop.example/home?q=%E0%A4',
      'https://shop.example/home#a%E0%A4',
      '/home/product/ada%E0%A4',
    ];

    test('tryParseUri yields null for it, a Uri otherwise', () {
      for (final u in bad) {
        expect(tryParseUri(u), isNull, reason: u);
      }
      expect(tryParseUri('https://shop.example/home/product/%C3%A9'),
          isNotNull);
    });

    test('the link matcher answers null', () {
      final product = SegBuilder.forScreen('product')
        ..children = {slot(Codec.string)};
      final m = LinkMatcher(
          LinkSpec([DomainNode('https://shop.example', linkRoot({product}))]));
      expect(m.parse('https://shop.example/product/a%E0%A4'), isNull);
      expect(m.parse('https://shop.example/product/ada')!.path, ['ada']);
    });

    test('parsePath, applyUrl and parseLink answer null / false', () {
      final g = _shop();
      for (final u in bad) {
        expect(g.parsePath(u), isNull, reason: u);
        expect(g.applyUrl(u), isFalse, reason: u);
        expect(g.parseLink(u), isNull, reason: u);
      }
      expect(g.parsePath('/home/product/sku-1'),
          [(P.home, null), (P.product, 'sku-1')]);
    });

    test('a fragment path with a broken escape decodes to nothing', () {
      expect(decodeFragmentPath({FragmentNode(Codec.string)}, 'a%E0%A4'),
          isNull);
    });
  });

  group('goFrom', () {
    test('goes along the edge from its anchor, popping what stands above',
        () async {
      final g = _shop();
      g.go(P.home);
      g.go(P.product, 'a');
      await _settle();
      g.go(P.review, 1, true);
      await _settle();
      g.goFrom(P.product, P.about, null);
      await _settle();
      expect(_stack(g), [(P.home, null), (P.product, 'a'), (P.about, null)]);
    });

    test('a repeat keeps the entry already standing there', () async {
      final g = _shop();
      g.go(P.home);
      g.go(P.product, 'a');
      await _settle();
      g.goFrom(P.product, P.review, 1);
      await _settle();
      final first = g.stack.last;
      var navigations = 0;
      g.navigations.listen((_) => navigations++);
      g.goFrom(P.product, P.review, 1); // the double tap
      await _settle();
      expect(identical(g.stack.last, first), isTrue);
      expect(navigations, 0);
    });

    test('lands on the standing entry, dropping what is above it', () async {
      final g = _shop();
      g.go(P.home);
      g.go(P.product, 'a');
      await _settle();
      g.goFrom(P.product, P.review, 1);
      await _settle();
      final review = g.stack.last;
      g.go(P.about, null, true);
      await _settle();
      g.goFrom(P.product, P.review, 1);
      await _settle();
      expect(identical(g.stack.last, review), isTrue);
      expect(_stack(g), [(P.home, null), (P.product, 'a'), (P.review, 1)]);
    });

    test('does nothing once its anchor has left the stack', () async {
      final g = _shop();
      g.go(P.home);
      await _settle();
      g.goFrom(P.product, P.review, 1);
      await _settle();
      expect(_stack(g), [(P.home, null)]);
    });
  });

  group('snapshots', () {
    test('end before an id its codec cannot carry', () async {
      final g = _shop();
      g.go(P.home);
      g.go(P.product, ''); // no token decodes back to ''
      await _settle();
      g.go(P.review, 3, true);
      await _settle();
      final scopes = g.toState()['scopes'] as Map;
      expect(scopes['home'], [
        ['home', null],
      ]);
    });

    test('restore drops fragment paths the snapshot does not carry',
        () async {
      final g = NavGraph({
        P.home({P.product().fragment.path(Codec.string)}),
      });
      g.go(P.home);
      await _settle();
      final blank = g.toState();
      g.setFragmentPath(P.product, ['x']);
      expect(g.fragmentPathOf(P.product), ['x']);
      expect(g.restore(blank), isTrue);
      expect(g.fragmentPathOf(P.product), isNull);
    });
  });
}
