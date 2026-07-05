import 'package:canon/canon.dart';
import 'package:test/test.dart';

/// A links-only grammar: NO fields at all — the enum names ARE the
/// declaration. What a server or API surface authors.
enum _Links with LinkNode<_Links> {
  shop,
  product,
  review;

  // ONE graph type for every tree — a spec-only NavGraph (no root, no
  // host): the graph knows link-only rows by their kind.
  static final graph = NavGraph({
    shop({
      product({review}),
    }),
  });
}

void main() {
  test('a fieldless enum authors a links-only tree', () {
    final trunks = _Links.graph.spec.trunks;
    expect(trunks, hasLength(1));
    expect(trunks.first.screen, _Links.shop);
    expect(trunks.first.children.single.screen, _Links.product);
    expect(trunks.first.children.single.children.single.screen, _Links.review);
  });

  test('id defaults null — nothing to declare on a pure link row', () {
    expect(_Links.product.id, isNull);
  });
}
