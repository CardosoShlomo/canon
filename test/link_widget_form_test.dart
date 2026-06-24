import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// The WIDGET form end-to-end at runtime: a bare `slots` in a real placement's
// children. `user` owns id `uuid`, so the assembler injects uuid as an extra
// union branch (after the leading literal) → order me(0), uuid(1), username(2).
enum W with ScreenNode<W> {
  home,
  user;

  @override
  Widget get widget => const SizedBox.shrink();

  @override
  Codec<Object?>? get id => this == user ? Codec.uuid : null;
}

class _Init implements InitialScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

void main() {
  final graph = NavGraph<_Init>(
    {
      W.home(),
      W.user({
        slots({Codec.literal('me'), Codec.username})
      }),
    },
    initial: const _Init([(W.home, null)]),
    pageOf: (w, c, k) => MaterialPage(child: w),
  );

  const uuid = '550e8400-e29b-41d4-a716-446655440000';

  test('injected id branch matches /user/<uuid> at index 1', () {
    final m = graph.parseLink('https://x.com/user/$uuid')!;
    expect(m.template, 'user/*');
    expect(m.branches, [1]); // me=0, uuid=1, username=2
    expect(m.path, [uuid]);
  });

  test('literal branch /user/me → index 0', () {
    expect(graph.parseLink('https://x.com/user/me')!.branches, [0]);
  });

  test('username branch /user/<name> → index 2', () {
    final m = graph.parseLink('https://x.com/user/ada')!;
    expect(m.branches, [2]);
    expect(m.path, ['ada']);
  });

  test('encode round-trips the injected id branch', () {
    expect(graph.encodeLink('https://x.com', 'user/*', [uuid], [1]),
        'https://x.com/user/$uuid');
  });
}
