import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// The WIDGET form end-to-end at runtime: a bare `slots` in a real placement's
// children. `author` owns id `uuid`, so the assembler injects uuid as the FIRST
// union branch (the canonical nav-target link leads) → uuid(0), me(1), username(2).
enum W with ScreenNode<W> {
  home,
  author;

  @override
  Widget get widget => const SizedBox.shrink();

  @override
  Codec<Object?>? get id => this == author ? Codec.uuid : null;
}

class _Init implements RootScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

void main() {
  final graph = NavGraph(
    {
      W.home(),
      W.author({
        slots({Codec.literal('me'), Codec.username})
      }),
    },
    seedChain: const _Init([(W.home, null)]),
    pageOf: (w, c, k) => MaterialPage(child: w),
  );

  const uuid = '550e8400-e29b-41d4-a716-446655440000';

  test('injected id branch matches /author/<uuid> at index 0', () {
    final m = graph.parseLink('https://x.com/author/$uuid')!;
    expect(m.template, 'author/*');
    expect(m.branches, [0]); // uuid=0, me=1, username=2
    expect(m.path, [uuid]);
  });

  test('literal branch /author/me → index 1', () {
    expect(graph.parseLink('https://x.com/author/me')!.branches, [1]);
  });

  test('username branch /author/<name> → index 2', () {
    final m = graph.parseLink('https://x.com/author/ada')!;
    expect(m.branches, [2]);
    expect(m.path, ['ada']);
  });

  test('encode round-trips the injected id branch', () {
    expect(graph.encodeLink('https://x.com', 'author/*', [uuid], [0]),
        'https://x.com/author/$uuid');
  });
}
