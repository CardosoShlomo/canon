import 'package:canon/canon.dart';
import 'package:test/test.dart';

enum Sort { asc, desc }

// /author/me                       (static, leaf)
// /author/<uuid|username>?loop     (slot union, flag query)
// /search?q=&sort=&tag=&tag=     (required single, optional enum, list)
final spec = LinkSpec([
  DomainNode(
    'https://example.com',
    LinkNode(statics: [
      StaticEdge(
        'author',
        LinkNode(
          statics: [StaticEdge('me', LinkNode(name: 'userMe', endpoint: true))],
          slot: SlotEdge(
            [Codec.uuid, Codec.string],
            LinkNode(
              name: 'author',
              query: ParamSchema(
                  [KeyDef('loop', mandatory: false)]), // codec null => flag
            ),
          ),
        ),
      ),
      StaticEdge(
        'search',
        LinkNode(name: 'search', query: ParamSchema([
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
}
