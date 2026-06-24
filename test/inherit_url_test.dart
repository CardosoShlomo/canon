import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// An inherited placement (editItem inherits item's id): the nav-mirror URL puts
// the id on the SOURCE segment only — the inherited segment is bare.
enum U with ScreenNode<U> {
  home,
  item,
  editItem;

  @override
  Widget get widget => const SizedBox.shrink();

  @override
  Codec<Object?>? get id =>
      (this == item || this == editItem) ? Codec.string : null;
}

class _Init implements InitialScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

NavGraph _mk() => NavGraph(
      {
        U.home({
          U.item({U.editItem.inherit(U.item)})
        })
      },
      seedChain: const _Init([(U.home, null)]),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

void main() {
  test('inherited segment is bare in the URL (id on the source only)', () async {
    final g = _mk();
    g.go(U.item, '42');
    g.go(U.editItem, '42', true);
    await Future<void>.delayed(Duration.zero);
    expect(g.currentUrl(), '/home/item/42/edit-item');
  });

  test('applyUrl reconstructs the inherited id from the source', () {
    final g = _mk();
    expect(g.applyUrl('/home/item/42/edit-item'), isTrue);
    expect([for (final e in g.stack) e.screen], [U.home, U.item, U.editItem]);
    expect(g.stack.last.id, '42'); // editItem's id reconstructed from item
  });
}
