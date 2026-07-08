import 'package:canon/canon.dart';
import 'package:test/test.dart';

class _Product {}

class _Author {}

class _Review {}

class _Comment {}

class _Reactor {}

enum _Ids with IdNode {
  product(Codec.string),
  author(Codec.string),
  review(Codec.string),
  comment(Codec.string);

  const _Ids(this.codec);
  @override
  final Codec codec;
}

@entities
enum _Entities with EntityNode<_Entities> {
  product(_Product, _Ids.product),
  author(_Author, _Ids.author),
  review(_Review, _Ids.review),
  comment(_Comment, _Ids.comment),
  reactor(_Reactor, _Ids.author); // keyed by who reacted

  const _Entities(this.type, this.key);
  @override
  final Type type;
  @override
  final IdNode key;

  static final graph = EntityGraph({
    author,
    product({review({comment, reactor})}),
  });
}

void main() {
  group('EntityGraph', () {
    test('roots and ownership derive from the tree', () {
      final g = _Entities.graph;
      expect(g.roots, {_Entities.author, _Entities.product});
      expect(g.isRoot(_Entities.product), isTrue);
      expect(g.isRoot(_Entities.comment), isFalse);
      expect(g.ownersOf(_Entities.review), {_Entities.product});
      expect(g.ownersOf(_Entities.comment), {_Entities.review});
      expect(g.ownersOf(_Entities.author), isEmpty);
    });

    test('one child kind may be owned by several parent kinds', () {
      final g = EntityGraph({
        _Entities.review({_Entities.reactor}),
        _Entities.comment({_Entities.reactor}),
      });
      expect(g.ownersOf(_Entities.reactor),
          {_Entities.review, _Entities.comment});
    });

    test('root-and-owned is a contradiction', () {
      expect(
        () => EntityGraph({
          _Entities.comment,
          _Entities.review({_Entities.comment}),
        }),
        throwsStateError,
      );
    });
  });
}
