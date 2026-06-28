import 'package:canon/canon.dart';
import 'package:test/test.dart';

// Query keys for the mandatory-gate tests.
enum _Cb with QueryKeyBase { code, state }

// Mirrors what NavGraph assembles at runtime from `.links` branches: each branch
// is a screen-rooted SegBuilder; `linkRoot` stitches them into the tree the
// matcher walks.
void main() {
  group('link parse (runtime tree from .links branches)', () {
    final user = SegBuilder.forScreen('user')..children = {slot(Codec.username)};
    final ad = SegBuilder.forScreen('ad')..children = {slot(Codec.uuid)};
    final root = linkRoot({user, ad});
    final spec = LinkSpec([DomainNode('https://allinloop.com', root)]);
    final m = LinkMatcher(spec);

    test('matches /user/<username> → template + path', () {
      final r = m.parse('https://allinloop.com/user/ada')!;
      expect(r.template, 'user/*');
      expect(r.path, ['ada']);
    });

    test('matches /ad/<uuid>', () {
      const u = '550e8400-e29b-41d4-a716-446655440000';
      final r = m.parse('https://allinloop.com/ad/$u')!;
      expect(r.template, 'ad/*');
      expect(r.path, [u]);
    });

    test('unknown path → null', () {
      expect(m.parse('https://allinloop.com/nope/x'), isNull);
    });
  });

  // A union slot `slots({literal('me'), uuid, username})` — the matcher reports
  // which branch matched, and printRoute re-selects it via `branches`. This is the
  // exact runtime path the generated parseLink/toUri delegates to.
  group('link union slot (branch round-trip)', () {
    final user = SegBuilder.forScreen('user')
      ..children = {
        slots({Codec.literal('me'), Codec.uuid, Codec.username})
      };
    final root = linkRoot({user});
    final spec = LinkSpec([DomainNode('https://allinloop.com', root)]);
    final m = LinkMatcher(spec);

    test('literal branch matches with index 0 and no payload to read', () {
      final r = m.parse('https://allinloop.com/user/me')!;
      expect(r.template, 'user/*');
      expect(r.branches, [0]);
      expect(r.path, ['me']);
    });

    test('uuid branch matches with index 1', () {
      const u = '550e8400-e29b-41d4-a716-446655440000';
      final r = m.parse('https://allinloop.com/user/$u')!;
      expect(r.branches, [1]);
      expect(r.path, [u]);
    });

    test('username branch matches with index 2', () {
      final r = m.parse('https://allinloop.com/user/ada')!;
      expect(r.branches, [2]);
      expect(r.path, ['ada']);
    });

    test('printRoute re-encodes the chosen branch', () {
      expect(
        m.printRoute(template: 'user/*', path: ['me'], branches: [0]),
        'https://allinloop.com/user/me',
      );
      expect(
        m.printRoute(template: 'user/*', path: ['ada'], branches: [2]),
        'https://allinloop.com/user/ada',
      );
    });
  });

  // `requireAllOf`/`requireOneOf` gate whether the URL MATCHES at all — an
  // OAuth-style /callback is meaningless without its query, so it must reject.
  group('mandatory query gate (requireAllOf)', () {
    final cb = SegBuilder.forScreen('callback').query({
      requireAllOf({_Cb.code(Codec.string), _Cb.state(Codec.string)})
    });
    final m =
        LinkMatcher(LinkSpec([DomainNode('https://app.com', linkRoot({cb}))]));

    test('matches when all required params present', () {
      expect(m.parse('https://app.com/callback?code=a&state=b'), isNotNull);
    });

    test('rejects when a required param is missing', () {
      expect(m.parse('https://app.com/callback?code=a'), isNull); // no state
      expect(m.parse('https://app.com/callback'), isNull); // none
    });
  });

  // `requireOneOf`: exactly one member, mandatory — none rejects, both reject.
  group('mandatory query gate (requireOneOf)', () {
    final cb = SegBuilder.forScreen('callback').query({
      requireOneOf({_Cb.code(Codec.string), _Cb.state(Codec.string)})
    });
    final m =
        LinkMatcher(LinkSpec([DomainNode('https://app.com', linkRoot({cb}))]));

    test('matches with exactly one present', () {
      expect(m.parse('https://app.com/callback?code=a'), isNotNull);
    });
    test('rejects when none present', () {
      expect(m.parse('https://app.com/callback'), isNull);
    });
    test('rejects when both present (mutual exclusion)', () {
      expect(m.parse('https://app.com/callback?code=a&state=b'), isNull);
    });
  });
}
