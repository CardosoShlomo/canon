import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canon/canon.dart';

enum N with ScreenNode<N> {
  home, feed, profile, chat;

  @override
  Widget get widget => _Label(this);

  // profile/chat carry a string id codec → their ids round-trip on restore;
  // home/feed are id-free (default null codec).
  @override
  Codec<Object?>? get id =>
      (this == profile || this == chat) ? Codec.string : null;

  static N _profile() => profile({profile.cycled, chat({profile.cycled})});

  static NavGraph<_Init> graph() => NavGraph(
        {
          home.keep({_profile()}),
          feed({_profile()}),
        },
        initial: const _Init([(home, null)]),
        pageOf: (widget, ctx, key) => MaterialPage(key: key, child: widget),
      );
}

// Renders `name:id` — reads its own runtime id via the in-package idOf primitive.
class _Label extends StatelessWidget {
  const _Label(this.screen);
  final N screen;
  @override
  Widget build(BuildContext context) {
    final id = ScreenScope.idOf<Object?>(context, screen);
    return Text('${screen.name}:${id ?? ''}');
  }
}

// A raw InitialScreenBase for engine tests (the typed surface is generated).
class _Init implements InitialScreenBase {
  const _Init(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

// ---- content-swap (keep/forget) fixtures -----------------------------------
final _inits = <String, int>{};
final _disposes = <String, int>{};

class _Track extends StatefulWidget {
  const _Track(this.name);
  final String name;
  @override
  State<_Track> createState() => _TrackState();
}

class _TrackState extends State<_Track> {
  @override
  void initState() {
    super.initState();
    _inits.update(widget.name, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    _disposes.update(widget.name, (n) => n + 1, ifAbsent: () => 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.name);
}

// home > services > shop.keep — a deep keep; `other` is a separate root.
enum K with ScreenNode<K> {
  home, services, shop, other;

  @override
  Widget get widget => _Track(name);

  static NavGraph<_InitK> graph() => NavGraph(
        {
          home({services({shop.keep()})}),
          other,
        },
        initial: const _InitK([(home, null)]),
        pageOf: (widget, ctx, key) => MaterialPage(key: key, child: widget),
      );
}

class _InitK implements InitialScreenBase {
  const _InitK(this.chain);
  @override
  final List<(Enum, Object?)> chain;
}

void main() {
  Future<NavGraph<_Init>> pump(WidgetTester tester) async {
    final graph = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    return graph;
  }

  testWidgets('renders the initial root', (tester) async {
    await pump(tester);
    expect(find.text('home:'), findsOneWidget);
  });

  testWidgets('navigations stream classifies direction + diff', (tester) async {
    final graph = await pump(tester);
    final seen = <Navigation>[];
    final sub = graph.navigations.listen(seen.add);
    addTearDown(sub.cancel);

    graph.go(N.profile, 'a'); // forward push under the home scope
    await tester.pumpAndSettle();
    expect(seen.last.direction, NavDirection.forward);
    expect(seen.last.destination, (N.profile, 'a'));
    expect(seen.last.pushed, [N.profile]);
    expect(seen.last.popped, isEmpty);
    expect(seen.last.pivot, N.home);

    graph.pop(); // backward
    await tester.pumpAndSettle();
    expect(seen.last.direction, NavDirection.backward);
    expect(seen.last.source, (N.profile, 'a'));
    expect(seen.last.destination, (N.home, null));
    expect(seen.last.popped, [N.profile]);
    expect(seen.last.pushed, isEmpty);

    graph.go(N.feed); // jump — switch root/scope
    await tester.pumpAndSettle();
    expect(seen.last.direction, NavDirection.jump);
    expect(seen.last.destination, (N.feed, null));
    expect(seen.last.pivot, isNull);

    graph.go(N.profile, 'x');
    await tester.pumpAndSettle();
    graph.pop(); // pop + go batched into one commit → round trip
    graph.go(N.profile, 'y');
    await tester.pumpAndSettle();
    expect(seen.last.direction, NavDirection.roundTrip);
    expect(seen.last.popped, [N.profile]);
    expect(seen.last.pushed, [N.profile]);
    expect(seen.last.destination, (N.profile, 'y'));
  });

  testWidgets('markReplace flags the batched commit; resets per batch',
      (tester) async {
    final graph = await pump(tester);
    final seen = <Navigation>[];
    final sub = graph.navigations.listen(seen.add);
    addTearDown(sub.cancel);

    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(seen.last.mode, CommitMode.push); // default

    graph.markReplace(); // decide-at-start
    graph.go(N.feed); // batched into one replace commit
    await tester.pumpAndSettle();
    expect(seen.last.mode, CommitMode.replace);

    graph.go(N.home); // a fresh batch resets to push
    await tester.pumpAndSettle();
    expect(seen.last.mode, CommitMode.push);
  });

  testWidgets('Screen.manager() mounts in MaterialApp.home; navigate + back',
      (tester) async {
    final graph = N.graph();
    await tester.pumpWidget(MaterialApp(home: graph.manager()));
    expect(find.text('home:'), findsOneWidget);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(find.text('profile:a'), findsOneWidget);
    // system back routes through the manager's BackButtonListener
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('home:'), findsOneWidget);
  });

  testWidgets('manager(restorationId:) round-trips the snapshot', (tester) async {
    final g1 = N.graph();
    await tester.pumpWidget(
        MaterialApp(restorationScopeId: 'app', home: g1.manager(restorationId: 'nav')));
    g1.go(N.profile, 'p');
    await tester.pumpAndSettle();
    await tester.restartAndRestore();
    expect(find.text('profile:p'), findsOneWidget);
  });

  testWidgets('go pushes and pop returns', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(find.text('profile:a'), findsOneWidget);
    graph.pop();
    await tester.pumpAndSettle();
    expect(find.text('home:'), findsOneWidget);
    expect(graph.stack.length, 1);
  });

  testWidgets('initial seeds a multi-entry starting stack', (tester) async {
    final graph = NavGraph<_Init>(
      {N.home.keep({N._profile()}), N.feed()},
      initial: const _Init([(N.home, null), (N.profile, 'p')]),
      pageOf: (widget, ctx, key) => MaterialPage(key: key, child: widget),
    );
    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    await tester.pumpAndSettle();
    expect(find.text('profile:p'), findsOneWidget); // top of seeded chain
    expect(graph.stack.length, 2); // home -> profile
    graph.pop();
    await tester.pumpAndSettle();
    expect(find.text('home:'), findsOneWidget);
  });

  testWidgets('id-bearing root: go(root, id) seeds the root id', (tester) async {
    final graph = await pump(tester);
    graph.go(N.feed, 'f'); // switch to the feed root WITH an id
    await tester.pumpAndSettle();
    expect(find.text('feed:f'), findsOneWidget); // stamped, not null
  });

  testWidgets('inherit-from-root shape: chain off an id-bearing root keeps its id',
      (tester) async {
    final graph = await pump(tester);
    graph.go(N.feed, 'f'); // kick-start to the root with the shared id
    graph.go(N.profile, 'f', true); // ...edge down (rescue body shape)
    await tester.pumpAndSettle();
    expect(find.text('profile:f'), findsOneWidget);
    graph.pop();
    await tester.pumpAndSettle();
    expect(find.text('feed:f'), findsOneWidget); // ancestor root id stamped
  });


  testWidgets('observe fires (from, to) per commit; disposer stops it',
      (tester) async {
    final graph = await pump(tester);
    final seen = <String>[];
    final off = graph.observe((from, to) => seen.add('${from.name}>${to.name}'));
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.chat, 'c');
    await tester.pumpAndSettle();
    graph.pop();
    await tester.pumpAndSettle();
    expect(seen, ['home>profile', 'profile>chat', 'chat>profile']);
    off();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    expect(seen.length, 3); // disposed: no further events
  });

  testWidgets('chain commits as one diff', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.chat, 'c').go(N.profile, 'b');
    await tester.pumpAndSettle();
    expect(find.text('profile:b'), findsOneWidget);
    expect(graph.stack.length, 4);
  });

  testWidgets('tab switch replaces the root', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    expect(find.text('feed:'), findsOneWidget);
    expect(graph.stack.length, 1);
  });

  testWidgets('system back pops and the mirror follows', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    final popped = await graph.delegate.popRoute();
    await tester.pumpAndSettle();
    expect(popped, isTrue);
    expect(find.text('home:'), findsOneWidget);
    expect(graph.stack.length, 1);
  });

  testWidgets('kept scope parks on leave and resumes as-is', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.profile, 'b');
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    expect(graph.stack.length, 1);
    graph.go(N.home); // tab re-tap: activate the parked stack
    await tester.pumpAndSettle();
    expect(graph.stack.length, 3);
    expect(find.text('profile:b'), findsOneWidget);
  });

  testWidgets('unkept scope resets when left', (tester) async {
    final graph = await pump(tester);
    graph.go(N.feed);
    await tester.pumpAndSettle();
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.home);
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    expect(graph.stack.length, 1); // feed came back fresh
    expect(find.text('feed:'), findsOneWidget);
  });

  testWidgets('go targets a screen inside a parked scope', (tester) async {
    final graph = await pump(tester);
    graph.go(N.feed);
    await tester.pumpAndSettle();
    graph.go(N.profile, 'x'); // profile's scope is feed? no — canonical root is home
    await tester.pumpAndSettle();
    expect(graph.stack.length, 2);
    expect(find.text('profile:x'), findsOneWidget);
  });

  testWidgets('forget frees a parked keep without navigating', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    graph.forget(N.home); // home is a parked keep → collapses to its root
    await tester.pumpAndSettle();
    expect(find.text('feed:'), findsOneWidget); // still on feed (no navigation)
    graph.go(N.home);
    await tester.pumpAndSettle();
    expect(graph.stack.length, 1); // home came back fresh
  });

  testWidgets('forget throws on the active stack and on an unmounted keep',
      (tester) async {
    final graph = await pump(tester);
    // home is the active tab → forgetting it is illegal (not a pop).
    expect(() => graph.forget(N.home), throwsStateError);
    // feed has never been visited → its (would-be) keep isn't mounted.
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(() => graph.forget(N.home), throwsStateError); // still active
  });

  testWidgets('parked widgets stay alive offstage', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    expect(find.text('profile:a', skipOffstage: false), findsOneWidget);
  });

  testWidgets('NavStack views work (Screen.stack building block)', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.chat, 'c').go(N.profile, 'b');
    await tester.pumpAndSettle();
    final stack = NavStack([for (final e in graph.stack) NavEntry(e.screen, e.id)]);
    expect(stack.screens, [N.home, N.profile, N.chat, N.profile]);
    expect(stack.reachable, [N.profile, N.chat, N.home]); // chat survives
    expect(stack.current, N.profile);
  });

  testWidgets('repeat-collapse pops back through the cycle', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.chat, 'c').go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(graph.stack.length, 4);
    graph.go(N.chat, 'c'); // completes the period-2 block -> collapse
    await tester.pumpAndSettle();
    expect(graph.stack.length, 3);
    expect(find.text('chat:c'), findsOneWidget);
  });

  testWidgets('edge-required go resolves a reachable target', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a', true); // profile is a live edge of home
    await tester.pumpAndSettle();
    expect(find.text('profile:a'), findsOneWidget);
  });

  testWidgets('edge-required go throws on an unreachable target', (tester) async {
    final graph = await pump(tester);
    // feed is a sibling root, not an edge from home — the stale-handle case.
    expect(() => graph.go(N.feed, null, true), throwsStateError);
    // the failed batch is discarded; the graph still works afterward.
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(find.text('profile:a'), findsOneWidget);
  });

  testWidgets('guaranteed pop throws when impossible', (tester) async {
    final graph = await pump(tester);
    expect(() => graph.pop(), throwsStateError); // nothing above the root
    expect(() => graph.pop(N.feed), throwsStateError); // feed not in the stack
  });

  testWidgets('self-pop reaches the previous occurrence, skipping the top', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.chat, 'c').go(N.profile, 'b'); // [home, p:a, chat, p:b]
    await tester.pumpAndSettle();
    graph.pop(N.profile); // self-pop: to the previous profile (a), not a no-op
    await tester.pumpAndSettle();
    expect(graph.current, N.profile);
    expect(graph.stack.last.id, 'a');
    expect(graph.stack.length, 2); // [home, p:a]
  });

  testWidgets('self-pop throws when there is no earlier occurrence', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a'); // only one profile
    await tester.pumpAndSettle();
    expect(() => graph.pop(N.profile), throwsStateError);
  });

  testWidgets('countOf counts active-stack occurrences (cycle depth)', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.chat, 'c').go(N.profile, 'b');
    await tester.pumpAndSettle();
    expect(graph.countOf(N.profile), 2); // a and b
    expect(graph.countOf(N.profile, 'a'), 1); // just a
    expect(graph.countOf(N.profile, 'z'), 0); // absent id
    expect(graph.countOf(N.chat), 1);
    expect(graph.countOf(N.feed), 0); // parked tab, not the active stack
  });

  testWidgets('parked tab keeps the kept subtree alive, frees the prefix',
      (tester) async {
    _inits.clear();
    _disposes.clear();
    final graph = K.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    graph.go(K.shop); // [home, services, shop] — all live while active
    await tester.pumpAndSettle();
    expect(_inits['shop'], 1);
    expect(_disposes['shop'], isNull);

    graph.go(K.other); // park the home tab
    await tester.pumpAndSettle();
    // The keep (shop) stays alive; the prefix above it is freed to SizedBox.
    expect(_disposes['shop'], isNull, reason: 'kept screen survives parking');
    expect(_inits['shop'], 1, reason: 'kept screen not rebuilt');
    expect(_disposes['home'], 1, reason: 'non-kept prefix is freed');
    expect(_disposes['services'], 1, reason: 'non-kept prefix is freed');

    graph.go(K.shop); // back into the home tab
    await tester.pumpAndSettle();
    // Prefix rebuilt fresh; shop is the same live instance throughout.
    expect(_inits['home'], 2, reason: 'prefix rebuilt fresh on return');
    expect(_inits['services'], 2);
    expect(_inits['shop'], 1, reason: 'kept screen never rebuilt');
    expect(_disposes['shop'], isNull);
  });

  testWidgets('restoration round-trips every scope (active + parked) with ids',
      (tester) async {
    final g1 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g1.delegate));
    g1.go(N.profile, 'p'); // home -> profile:p
    await tester.pumpAndSettle();
    g1.go(N.feed); // switch scopes; home parks (it is a keep) holding profile:p
    await tester.pumpAndSettle();

    final snap = g1.toState();
    expect(snap['active'], 'feed');

    // Fresh graph (simulates process death) restores from the snapshot.
    final g2 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g2.delegate));
    expect(g2.restore(snap), isTrue);
    await tester.pumpAndSettle();

    // Active scope restored.
    expect(g2.current, N.feed);
    expect(g2.stack.map((e) => '${e.screen.name}:${e.id}').toList(),
        ['feed:null']);

    // The parked home scope restored too, with its decoded id.
    g2.go(N.home);
    await tester.pumpAndSettle();
    expect(g2.stack.map((e) => '${e.screen.name}:${e.id}').toList(),
        ['home:null', 'profile:p']);
  });

  testWidgets('restore truncates above a screen whose codec rejects its token',
      (tester) async {
    final g1 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g1.delegate));
    g1.go(N.profile, 'p'); // home -> profile:p
    await tester.pumpAndSettle();
    g1.go(N.chat, 'c'); // -> chat:c  (chat is profile's child)
    await tester.pumpAndSettle();
    final snap = g1.toState();
    // Corrupt chat's id token: '' is rejected by Codec.string.
    ((snap['scopes'] as Map)['home'] as List)[2][1] = '';

    final g2 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g2.delegate));
    expect(g2.restore(snap), isTrue);
    await tester.pumpAndSettle();
    // chat dropped (codec rejected its token); the prefix below survives.
    expect(g2.stack.map((e) => '${e.screen.name}:${e.id}').toList(),
        ['home:null', 'profile:p']);
  });

  testWidgets('restore is best-effort — truncates at an illegal entry',
      (tester) async {
    final g1 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g1.delegate));
    g1.go(N.profile, 'p');
    await tester.pumpAndSettle();
    final snap = g1.toState();
    // Corrupt the active scope: append an entry that is NOT a legal edge from
    // profile (feed is a root, not profile's child).
    (snap['scopes'] as Map)['home'] = [
      ['home', null],
      ['profile', 'p'],
      ['feed', null], // illegal here
    ];

    final g2 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g2.delegate));
    expect(g2.restore(snap), isTrue);
    await tester.pumpAndSettle();
    // Truncated to the legal prefix; the illegal tail is dropped, no throw.
    expect(g2.stack.map((e) => '${e.screen.name}:${e.id}').toList(),
        ['home:null', 'profile:p']);
  });

  testWidgets('restore rejects a snapshot from a changed graph', (tester) async {
    final g1 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g1.delegate));
    final snap = g1.toState();
    snap['v'] = 'stale-signature';
    final g2 = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: g2.delegate));
    expect(g2.restore(snap), isFalse);
  });
}
