import 'package:test/test.dart';
import 'package:canon/canon.dart' hide Msg;

final thumb = Codec.literal('thumb');
final gallery = Codec.literal('gallery');
final zoom = Codec.literal('zoom');
final deals = Codec.literal('deals');

void main() {
  // #deals · #<uuid> · #<uuid>/thumb · #<uuid>/gallery/<int>/zoom
  final roots = fragmentRoots({
    deals,
    Codec.string / {thumb, gallery / (Codec.integer / {zoom})},
  });

  group('decode', () {
    test('a bare literal anchor', () {
      expect(decodeFragmentPath(roots, 'deals'), ['deals']);
    });

    test('a slug, then branches', () {
      expect(decodeFragmentPath(roots, 'p42'), ['p42']);
      expect(decodeFragmentPath(roots, 'p42/thumb'), ['p42', 'thumb']);
      expect(decodeFragmentPath(roots, 'p42/gallery/3/zoom'),
          ['p42', 'gallery', 3, 'zoom']);
    });

    test('STRICT: any bad position rejects the whole fragment', () {
      expect(decodeFragmentPath(roots, 'p42/nope'), isNull);
      expect(decodeFragmentPath(roots, 'p42/gallery/x'), isNull);
      expect(decodeFragmentPath(roots, 'p42/thumb/extra'), isNull);
    });

    test('no leading slash — not an alias spelling', () {
      expect(decodeFragmentPath(roots, '/p42'), isNull);
    });

    test('a :~: directive tail is user-agent territory — stripped', () {
      expect(decodeFragmentPath(roots, 'p42/thumb:~:text=hello'),
          ['p42', 'thumb']);
    });
  });

  group('encode', () {
    test('round-trips every legal path', () {
      for (final raw in ['deals', 'p42', 'p42/thumb', 'p42/gallery/3/zoom']) {
        final decoded = decodeFragmentPath(roots, raw)!;
        expect(encodeFragmentPath(roots, decoded), raw);
      }
    });

    test('an illegal write encodes to null', () {
      expect(encodeFragmentPath(roots, ['p42', 'nope']), isNull);
      expect(encodeFragmentPath(roots, []), isNull);
    });
  });
}
