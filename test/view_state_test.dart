import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// Screen-local view-state declared on a placement, mirrored into ?query.
enum FeedKeys with QueryKeyBase { category, radius }

enum V with ScreenNode<V> {
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

NavGraph _mk() => NavGraph(
      {
        V.home(),
        V.feed().query({
          FeedKeys.category(Codec.string),
          FeedKeys.radius(Codec.integer),
        }),
      },
      seedChain: const _Init([(V.feed, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

void main() {
  test('view-state mirrors into the URL query (omitting unset keys)', () {
    final g = _mk();
    expect(g.currentUrl(), '/feed'); // nothing set → no query
    g.viewSet(V.feed, 'category', 'books');
    g.viewSet(V.feed, 'radius', 7);
    expect(g.currentUrl(), '/feed?category=books&radius=7');
  });

  test('applyUrl decodes the query into typed view-state', () {
    final g = _mk();
    expect(g.applyUrl('/feed?category=books&radius=7'), isTrue);
    expect(g.viewGet(V.feed, 'category'), 'books');
    expect(g.viewGet(V.feed, 'radius'), 7); // codec-typed (int, not '7')
  });

  test('setting null clears (absent ⟺ default)', () {
    final g = _mk();
    g.viewSet(V.feed, 'category', 'books');
    g.viewSet(V.feed, 'category', null);
    expect(g.currentUrl(), '/feed');
  });

  test('toState/restore round-trips view-state', () {
    final g = _mk();
    g.viewSet(V.feed, 'category', 'books');
    g.viewSet(V.feed, 'radius', 7);
    final blob = g.toState();

    final g2 = _mk();
    expect(g2.restore(blob), isTrue);
    expect(g2.viewGet(V.feed, 'category'), 'books');
    expect(g2.viewGet(V.feed, 'radius'), 7);
  });
}
