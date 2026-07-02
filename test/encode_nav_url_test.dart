import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// `encodeNavUrl` prints a nav path → URL from an explicit chain (the static
// counterpart of `currentUrl`), so a typed `WidgetLink` can build its URL
// without touching the live stack.
enum S with ScreenNode<S> {
  home,
  settings,
  author;

  @override
  Widget get widget => const SizedBox.shrink();

  @override
  Codec<Object?>? get id => this == author ? Codec.uuid : null;
}

void main() {
  final graph = NavGraph(
    {
      S.home({S.settings()}),
      S.author(),
    },
    seedChain: const _Init([(S.home, null)]),
    pageOf: (w, c, k) => MaterialPage(child: w),
  );
  const uuid = '550e8400-e29b-41d4-a716-446655440000';

  test('id-free path encodes its kebab segments', () {
    expect(graph.encodeNavUrl('https://x.com', [S.home, S.settings], [null, null]),
        'https://x.com/home/settings');
  });

  test('an id-bearing segment appends its encoded token', () {
    expect(graph.encodeNavUrl('https://x.com', [S.author], [uuid]),
        'https://x.com/author/$uuid');
  });

  test('a value the codec rejects throws (would be unparseable)', () {
    expect(() => graph.encodeNavUrl('https://x.com', [S.author], ['not-a-uuid']),
        throwsArgumentError);
  });
}

class _Init implements RootScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}
