import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:canon/canon.dart';

enum N with ScreenNode<Object?, N> {
  home, feed, profile, chat;

  static N _profile() => profile({profile.cycled, chat({profile.cycled})});

  static NavGraph<N> graph() => NavGraph(
        {
          home.keep({_profile()}),
          feed({_profile()}),
        },
        initial: home,
        pageOf: (screen, ctx, key) => MaterialPage(
          key: key,
          child: ScreenScope(
            entry: ctx.entry,
            child: Text('${screen.name}:${ctx.entry.id ?? ''}'),
          ),
        ),
      );
}

void main() {
  Future<NavGraph<N>> pump(WidgetTester tester) async {
    final graph = N.graph();
    await tester.pumpWidget(MaterialApp.router(routerDelegate: graph.delegate));
    return graph;
  }

  testWidgets('renders the initial root', (tester) async {
    await pump(tester);
    expect(find.text('home:'), findsOneWidget);
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

  testWidgets('reset collapses a parked scope without navigating', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    graph.reset(N.home);
    await tester.pumpAndSettle();
    expect(find.text('feed:'), findsOneWidget); // still on feed
    graph.go(N.home);
    await tester.pumpAndSettle();
    expect(graph.stack.length, 1); // home came back fresh
  });

  testWidgets('parked widgets stay alive offstage', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    graph.go(N.feed);
    await tester.pumpAndSettle();
    expect(find.text('profile:a', skipOffstage: false), findsOneWidget);
  });

  testWidgets('maybePop returns false when the target is not in the stack', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a');
    await tester.pumpAndSettle();
    expect(graph.maybePop(N.chat), isFalse); // chat absent — no-op
    await tester.pumpAndSettle();
    expect(graph.stack.length, 2); // unchanged
  });

  testWidgets('maybePop returns false when a bare pop hits the root', (tester) async {
    final graph = await pump(tester);
    expect(graph.maybePop(), isFalse); // only [home] — nothing to pop
  });

  testWidgets('maybePop returns true and pops when the target is present', (tester) async {
    final graph = await pump(tester);
    graph.go(N.profile, 'a').go(N.chat, 'c');
    await tester.pumpAndSettle();
    expect(graph.maybePop(N.profile), isTrue);
    await tester.pumpAndSettle();
    expect(graph.current, N.profile);
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
}
