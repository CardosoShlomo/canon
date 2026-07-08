import 'package:canon/canon.dart';
import 'package:test/test.dart';

enum Sort { asc, desc }

// /author/me                       (static, leaf)
// /author/<uuid|username>?loop     (slot union, flag query)
// /search?q=&sort=&tag=&tag=     (required single, optional enum, list)
final spec = LinkSpec([
  DomainNode(
    'https://example.com',
    PathNode(statics: [
      StaticEdge(
        'author',
        PathNode(
          statics: [StaticEdge('me', PathNode(name: 'userMe', endpoint: true))],
          slot: SlotEdge(
            [Codec.uuid, Codec.string],
            PathNode(
              name: 'author',
              query: ParamSchema(
                  [KeyDef('loop', mandatory: false)]), // codec null => flag
            ),
          ),
        ),
      ),
      StaticEdge(
        'search',
        PathNode(name: 'search', query: ParamSchema([
          KeyDef('q', codec: Codec.string),
          KeyDef('sort', codec: Codec.enumValues(Sort.values), mandatory: false),
          KeyDef('tag', codec: Codec.string, list: true),
        ])),
      ),
    ]),
  ),
]);

final m = LinkMatcher(spec);

void main() {
  group('phase 1 — committed fallthrough', () {
    test('static beats slot', () {
      expect(m.parse('https://example.com/author/me')!.name, 'userMe');
    });
    test('committed static does NOT backtrack to slot', () {
      // me commits; me is a leaf; /posts has no edge => null (not username "me")
      expect(m.parse('https://example.com/author/me/posts'), isNull);
    });
    test('union: uuid branch first', () {
      const u = '550e8400-e29b-41d4-a716-446655440000';
      final r = m.parse('https://example.com/author/$u')!;
      expect(r.name, 'author');
      expect(r.path, [u]);
    });
    test('union: falls through to username', () {
      final r = m.parse('https://example.com/author/ada')!;
      expect(r.name, 'author');
      expect(r.path, ['ada']);
    });
    test('unknown domain => null', () {
      expect(m.parse('https://evil.com/author/ada'), isNull);
    });
    test('host boundary — no prefix spoofing', () {
      expect(m.parse('https://example.com.evil.com/author/ada'), isNull);
      expect(m.parse('https://example.community/author/ada'), isNull);
    });
    test('scheme/host case-insensitive', () {
      expect(m.parse('HTTPS://EXAMPLE.com/author/ada')!.name, 'author');
    });
    test('wrong scheme => null', () {
      expect(m.parse('http://example.com/author/ada'), isNull);
    });
    test('non-endpoint root => null', () {
      expect(m.parse('https://example.com/'), isNull);
    });
  });

  group('phase 2 — params', () {
    test('flag absent / present', () {
      expect(m.parse('https://example.com/author/ada')!.query['loop'], false);
      expect(
          m.parse('https://example.com/author/ada?loop')!.query['loop'], true);
    });
    test('required single missing => null', () {
      expect(m.parse('https://example.com/search'), isNull);
    });
    test('list preserves occurrence order', () {
      final r = m.parse('https://example.com/search?q=x&tag=a&tag=b')!;
      expect(r.query['q'], 'x');
      expect(r.query['tag'], ['a', 'b']);
    });
    test('optional enum + bad value', () {
      expect(m.parse('https://example.com/search?q=x&sort=desc')!
          .query['sort'], Sort.desc);
      expect(m.parse('https://example.com/search?q=x&sort=sideways'), isNull);
    });
    test('unmodeled key ignored, dropped on print', () {
      final r = m.parse('https://example.com/search?q=x&utm_source=fb')!;
      expect(r.query['q'], 'x');
      expect(m.print(r), 'https://example.com/search?q=x');
    });
  });

  group('round-trip (print ∘ parse == identity on canonical)', () {
    for (final url in [
      'https://example.com/author/me',
      'https://example.com/author/550e8400-e29b-41d4-a716-446655440000',
      'https://example.com/author/ada',
      'https://example.com/author/ada?loop',
      'https://example.com/search?q=hello&sort=desc&tag=a&tag=b',
    ]) {
      test(url, () => expect(m.print(m.parse(url)!), url));
    }
  });

  group('affix segments via concat codec', () {
    // `ads/<id>/<index>` and `ads/<id>/<index>_thumb` — one union slot whose
    // thumb branch is a concat codec. No structural suffix; the codec carries it.
    final cdn = LinkMatcher(LinkSpec([
      DomainNode(
        'https://cdn.example.com',
        PathNode(statics: [
          StaticEdge(
            'ads',
            PathNode(slot: SlotEdge([Codec.uuid], PathNode(statics: [
              StaticEdge('thumb', PathNode(name: 'adThumb')),
            ], slot: SlotEdge([
              Codec.integer + Codec.literal('_thumb'), // branch 0
              Codec.integer, // branch 1
            ], PathNode(name: 'image', endpoint: true))))),
          ),
        ]),
      ),
    ]));
    const ad = '550e8400-e29b-41d4-a716-446655440000';

    test('the concat branch decodes the affixed segment (template stays *)', () {
      final match = cdn.parse('https://cdn.example.com/ads/$ad/2_thumb')!;
      expect(match.path, [ad, 2]);
      expect(match.template, 'ads/*/*');
      expect(match.branches, [0, 0]); // uuid slot single, then thumb branch 0
    });

    test('the bare branch takes the unaffixed segment', () {
      final match = cdn.parse('https://cdn.example.com/ads/$ad/2')!;
      expect(match.branches, [0, 1]);
    });

    test('a static sibling still wins over the slot', () {
      expect(cdn.parse('https://cdn.example.com/ads/$ad/thumb')!.template,
          'ads/*/thumb');
    });

    test('printRoute picks the codec by branch (thumb)', () {
      expect(
          cdn.printRoute(template: 'ads/*/*', path: [ad, 0], branches: [0, 0]),
          'https://cdn.example.com/ads/$ad/0_thumb');
    });

    test('printRoute bare branch', () {
      expect(
          cdn.printRoute(template: 'ads/*/*', path: [ad, 0], branches: [0, 1]),
          'https://cdn.example.com/ads/$ad/0');
    });

    test('round-trips the affixed url', () {
      const url = 'https://cdn.example.com/ads/$ad/3_thumb';
      expect(cdn.print(cdn.parse(url)!), url);
    });
  });
}
