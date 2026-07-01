import 'package:canon/canon.dart';
import 'package:test/test.dart';

// A hand-written @ids enum: the id-space IS this enum. Named identities,
// a composite, and value-codec passthroughs are all just rows. No generation.
@IDs()
enum Ids with IdNode {
  author(.uuid),
  product(.uuid),
  string(.string),
  integer(.integer);

  const Ids(this.codec);
  @override
  final Codec codec;

  // Composite identity (product, author) — a review is keyed by both.
  static const IdNode review = .compose(product, author);
}

// A screens-shaped enum referencing the id-space by dot-shorthand — the spec
// points at a spec type (IdNode), never anything generated.
enum Screen {
  profile(id: Ids.author),
  review(id: Ids.review),
  search(id: Ids.string);

  const Screen({required this.id});
  final IdNode id;
}

void main() {
  test('screen rows reference the @ids enum', () {
    expect(Screen.profile.id, Ids.author);
    expect(Screen.review.id, Ids.review);
    expect(Screen.search.id, Ids.string);
  });

  const uuidA = '11111111-1111-1111-1111-111111111111';
  const uuidB = '22222222-2222-2222-2222-222222222222';

  test('each id-node carries a codec that round-trips its key', () {
    expect(Ids.author.codec.encode(uuidA), uuidA);
    expect(Ids.author.codec.decode(uuidA), uuidA);
    expect(Ids.integer.codec.encode(7), '7');
    expect(Ids.integer.codec.decode('7'), 7);
  });

  test('a composite id-node serialises the record key', () {
    final codec = Ids.review.codec;
    final encoded = codec.encode((uuidA, uuidB));
    expect(codec.decode(encoded), (uuidA, uuidB));
  });
}
