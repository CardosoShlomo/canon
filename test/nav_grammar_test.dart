import 'package:canon/src/screen_node.dart';
import 'package:test/test.dart';

// A miniature social-app tree: tabs, a profile cycle, and a leaf settings branch.
enum S with ScreenNodeBase<S, Object> {
  home, feed, settings, language, profile, friends, chat;

  // Pure-VM test: W is bound to Object, widget is irrelevant to the grammar.
  @override
  Object get widget => name;

  static S _userProfile() => profile({
        profile.cycled,
        friends({profile.cycled}),
        chat({profile.cycled}),
      });

  static NavSpec<S> spec() => NavSpec({
        home({_userProfile()}),
        feed({_userProfile()}),
        settings({language}),
      });
}

extension on NavSpec<S> {
  StackEntry<S> entry(S screen, [Object? id]) =>
      StackEntry(canonical[screen]!, id);
}

void main() {
  group('grammar build', () {
    test('claims nodes post-order into the right parents', () {
      final s = S.spec();
      final homeNode = s.canonical[S.home]!;
      expect(homeNode.children.map((n) => n.screen), [S.profile]);
      expect(s.canonical[S.profile]!.parent, homeNode);
      expect(s.canonical[S.friends]!.children.single.again, isTrue);
    });

    test('bare refs become leaves', () {
      final s = S.spec();
      expect(s.canonical[S.language]!.children, isEmpty);
    });

    test('canonical is the first placement', () {
      final s = S.spec();
      expect(s.canonical[S.profile]!.parent!.screen, S.home); // not S.feed
    });

    test('again with no ancestor throws at build', () {
      expect(() => NavSpec<S>({S.home({S.friends.cycled})}),
          throwsStateError);
    });

    test('keep below the root throws at build', () {
      expect(() => NavSpec<S>({S.home({S.profile.keep()})}),
          throwsStateError);
    });

    test('a failed build never poisons the next construction', () {
      expect(() => NavSpec<S>({S.home({S.friends.cycled})}),
          throwsStateError);
      final s = S.spec();
      expect(s.canonical[S.home]!.children.map((n) => n.screen), [S.profile]);
      expect(s.isMulti(S.settings), isFalse);
    });

    test('multi-instance kind derives from again and multiple placements', () {
      final s = S.spec();
      expect(s.isMulti(S.profile), isTrue); // again-target
      expect(s.isMulti(S.friends), isTrue); // placed under both home and feed
      expect(s.isMulti(S.settings), isFalse);
      expect(s.isMulti(S.language), isFalse);
    });
  });

  group('structure signature', () {
    test('is sibling-order independent', () {
      final a = NavSpec<S>({S.home({S.settings, S.language})}).structureSignature;
      final b = NavSpec<S>({S.home({S.language, S.settings})}).structureSignature;
      expect(a, b);
    });

    test('re-parenting changes the signature', () {
      final a = NavSpec<S>({S.home({S.language}), S.settings()}).structureSignature;
      final b = NavSpec<S>({S.home(), S.settings({S.language})}).structureSignature;
      expect(a, isNot(b));
    });

    test('reflects keep and again flags', () {
      expect(NavSpec<S>({S.home.keep({S.language})}).structureSignature,
          contains('homeK('));
      expect(S.spec().structureSignature, contains('profileA'));
    });

    test('identical trees produce identical signatures', () {
      expect(S.spec().structureSignature, S.spec().structureSignature);
    });
  });

  group('again resolution', () {
    test('back-edge adopts the nearest same-screen ancestor node', () {
      final s = S.spec();
      final friendsNode = s.canonical[S.friends]!;
      final backEdge = friendsNode.children.single;
      expect(backEdge.resolved, same(s.canonical[S.profile]));
    });
  });

  group('resolveGo ladder', () {
    test('rung 1: first recurrence is NOT a repeat — pushes a new page', () {
      // profile<a> -> chat<a> -> back to profile<a> via the chat header
      final s = S.spec();
      final stack = [
        s.entry(S.home),
        s.entry(S.profile, 'a'),
        s.entry(S.chat, ('x', 'a')),
      ];
      final r = resolveGo(s, stack, S.profile, 'a');
      expect(r.popCount, 0);
      expect(r.pushes.single.screen, S.profile);
    });

    test('rung 1: re-tapping the top page is a no-op (period 1)', () {
      final s = S.spec();
      final stack = [s.entry(S.home), s.entry(S.profile, 'a')];
      final r = resolveGo(s, stack, S.profile, 'a');
      expect(r.popCount, 0);
      expect(r.pushes, isEmpty);
    });

    test('rung 1: completing a repeated block collapses to its previous occurrence', () {
      // up<a>/chat<a>/up<a> + chat<a> -> period 2: pop back to chat<a>
      final s = S.spec();
      final stack = [
        s.entry(S.home),
        s.entry(S.profile, 'a'),
        s.entry(S.chat, ('x', 'a')),
        s.entry(S.profile, 'a'),
      ];
      final r = resolveGo(s, stack, S.chat, ('x', 'a'));
      expect(r.popCount, 1);
      expect(r.pushes, isEmpty);
    });

    test('rung 1: period-4 cycle collapses per the original spec', () {
      // up<a>/f<a>/up<b>/f<b>/up<a>/f<a>/up<b> + f<b> -> pop 3 to the previous f<b>
      final s = S.spec();
      final stack = [
        s.entry(S.home),
        s.entry(S.profile, 'a'),
        s.entry(S.friends, 'a'),
        s.entry(S.profile, 'b'),
        s.entry(S.friends, 'b'),
        s.entry(S.profile, 'a'),
        s.entry(S.friends, 'a'),
        s.entry(S.profile, 'b'),
      ];
      final r = resolveGo(s, stack, S.friends, 'b');
      expect(r.popCount, 3);
      expect(r.pushes, isEmpty);
    });

    test('rung 2: again-edge pushes a DIFFERENT id of the same screen', () {
      final s = S.spec();
      final stack = [s.entry(S.home), s.entry(S.profile, 'a')];
      final r = resolveGo(s, stack, S.profile, 'b');
      expect(r.popCount, 0);
      expect(r.pushes.single.id, 'b');
      expect(r.pushes.single.node, same(s.canonical[S.profile]));
    });

    test('rung 2: cycle sustains through the loop (profile/friends/profile)', () {
      final s = S.spec();
      final stack = [
        s.entry(S.home),
        s.entry(S.profile, 'a'),
        s.entry(S.friends, 'a'),
      ];
      final r = resolveGo(s, stack, S.profile, 'b');
      expect(r.pushes.single.screen, S.profile);
      // the pushed page adopted the canonical node, so the walk continues
      expect(resolveGo(s, [...stack, r.pushes.single], S.friends, 'b').pushes,
          isNotEmpty);
    });

    test('rung 3: tab switch pops everything, pushes the root', () {
      final s = S.spec();
      final stack = [s.entry(S.home), s.entry(S.profile, 'a')];
      final r = resolveGo(s, stack, S.feed, null);
      expect(r.popCount, 2);
      expect(r.pushes.map((e) => e.screen), [S.feed]);
    });

    test('rung 3: go to the live root keeps its entry — pops children only', () {
      final s = S.spec();
      final stack = [s.entry(S.home), s.entry(S.profile, 'a')];
      final r = resolveGo(s, stack, S.home, null);
      expect(r.popCount, 1);
      expect(r.pushes, isEmpty);
    });

    test('rung 3: canonical reuses the live common prefix', () {
      final s = S.spec();
      final stack = [s.entry(S.settings)];
      final r = resolveGo(s, stack, S.language, null);
      expect(r.popCount, 0);
      expect(r.pushes.map((e) => e.screen), [S.language]);
    });

    test('rung 3 fires the missing-edge diagnostic for non-root targets', () {
      final s = S.spec();
      String? warned;
      resolveGo(s, [s.entry(S.home)], S.language, null,
          onCanonicalFallback: (m) => warned = m);
      expect(warned, contains('language'));
    });
  });

  group('stacked back-edge', () {
    test('cycled folds a completed cycle; stacked pushes a fresh instance', () {
      final cycled = NavSpec<S>({S.profile({S.chat({S.profile.cycled})})});
      final stacked = NavSpec<S>({S.profile({S.chat({S.profile.stacked})})});
      List<StackEntry<S>> stk(NavSpec<S> s) => [
            s.entry(S.profile, 'a'),
            s.entry(S.chat, ('x', 'a')),
            s.entry(S.profile, 'a'),
            s.entry(S.chat, ('x', 'a')),
          ];
      final c = resolveGo(cycled, stk(cycled), S.profile, 'a');
      expect(c.popCount, 1); // folds back to the previous occurrence
      expect(c.pushes, isEmpty);

      final s = resolveGo(stacked, stk(stacked), S.profile, 'a');
      expect(s.popCount, 0); // keeps the stack
      expect(s.pushes.single.screen, S.profile);
    });

    test('stacked pushes a fresh instance even for an exact duplicate of the top', () {
      final stacked = NavSpec<S>({S.profile({S.profile.stacked})});
      final r = resolveGo(stacked, [stacked.entry(S.profile, 'a')], S.profile, 'a');
      expect(r.popCount, 0);
      expect(r.pushes.length, 1);
      expect(r.pushes.single.screen, S.profile);
      expect(r.pushes.single.id, 'a');
    });
  });

  group('resolvePop', () {
    test('pop once', () {
      final s = S.spec();
      final stack = [s.entry(S.home), s.entry(S.profile, 'a')];
      expect(resolvePop(stack, null)!.popCount, 1);
    });

    test('pop on a root fails (chain failure)', () {
      final s = S.spec();
      expect(resolvePop([s.entry(S.home)], null), isNull);
    });

    test('pop until nearest target, which survives', () {
      final s = S.spec();
      final profileNode = s.canonical[S.profile]!;
      final stack = [
        s.entry(S.home),
        StackEntry(profileNode, 'a'),
        StackEntry(profileNode, 'b'),
        s.entry(S.friends, 'b'),
      ];
      final r = resolvePop(stack, S.profile)!;
      expect(r.popCount, 1); // nearest S.profile is 'b'
    });

    test('pop until absent target fails', () {
      final s = S.spec();
      expect(resolvePop([s.entry(S.home)], S.chat), isNull);
    });
  });
}
