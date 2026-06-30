import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// Composite-inherited placements. `booking` composes its `(String, String)` id
// from room + guest; `review` composes a `(String, int)` id, inheriting only the
// String component from room (the int rides review's own segment — the PARTIAL
// case). The nav-mirror URL puts each inherited component on its SOURCE segment.
enum C with ScreenNode<C> {
  room,
  guest,
  booking,
  review;

  @override
  Widget get widget => const SizedBox.shrink();

  @override
  Codec<Object?>? get id => switch (this) {
        room || guest => Codec.string,
        booking => Codec.record2(Codec.string, Codec.string),
        review => Codec.record2(Codec.string, Codec.integer),
      };
}

class _Init implements RootScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

NavGraph _mk() => NavGraph(
      {
        C.room({
          C.guest({C.booking.inherit(C.room, C.guest)}),
          C.review.inherit(C.room),
        })
      },
      seedChain: const _Init([(C.room, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

void main() {
  test('fully composite-inherited segment is bare (both ids on the sources)',
      () async {
    final g = _mk();
    g.go(C.room, 'r1');
    g.go(C.guest, 'g1', true);
    g.go(C.booking, ('r1', 'g1'), true);
    await Future<void>.delayed(Duration.zero);
    expect(g.currentUrl(), '/room/r1/guest/g1/booking');
  });

  test('parsing reconstructs booking\'s full composite id from the sources', () {
    final g = _mk();
    expect(g.applyUrl('/room/r1/guest/g1/booking'), isTrue);
    expect([for (final e in g.stack) e.screen], [C.room, C.guest, C.booking]);
    expect(g.stack.last.id, ('r1', 'g1'));
  });

  test('partial composite: inherited component bare, own component on segment',
      () async {
    final g = _mk();
    g.go(C.room, 'r1');
    g.go(C.review, ('r1', 7), true);
    await Future<void>.delayed(Duration.zero);
    expect(g.currentUrl(), '/room/r1/review/7');
  });

  test('parsing a partial composite fills inherited + own components', () {
    final g = _mk();
    expect(g.applyUrl('/room/r1/review/7'), isTrue);
    expect([for (final e in g.stack) e.screen], [C.room, C.review]);
    expect(g.stack.last.id, ('r1', 7));
  });
}
