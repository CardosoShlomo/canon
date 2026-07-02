import 'package:canon/src/screen_node.dart';
import 'package:test/test.dart';

// A miniature social-app tree: tabs, a profile cycle, and a leaf settings branch.
enum S with ScreenNodeBase<S, Object> {
  home, feed, settings, language, profile, friends, review;

  // Pure-VM test: W is bound to Object, widget is irrelevant to the grammar.
  @override
  Object get widget => name;

  static S _userProfile() => profile({
        profile.cycled,
        friends({profile.cycled}),
        review({profile.cycled}),
      });

  static NavSpec spec() => NavSpec({
        home({_userProfile()}),
        feed({_userProfile()}),
        settings({language}),
      });
}

// A separate screen family, mounted into S's tree via `graft`.
enum Sub with ScreenNodeBase<Sub, Object> {
  shop, catalog;

  @override
  Object get widget => name;

  static Sub tree() => shop({catalog});
}

// Shared-screen model: `profile` is OWNED by Own (carries a widget); Ref
// re-declares `profile` as a bare REF (null widget) so it can be reused
// in-family, and canonicalization collapses the ref to the owner.
enum Own with ScreenNodeBase<Own, Object?> {
  home,
  profile;

  @override
  Object? get widget => name; // both owners
}

enum Ref with ScreenNodeBase<Ref, Object?> {
  shop,
  profile;

  @override
  Object? get widget => this == profile ? null : name; // profile is a ref

  static Ref tree() => shop({profile});
}

enum TwoOwners with ScreenNodeBase<TwoOwners, Object?> {
  profile; // a SECOND owner of `profile` — also carries a widget

  @override
  Object? get widget => name;
}

enum Dangling with ScreenNodeBase<Dangling, Object?> {
  ghost; // a ref (null widget) with no owner anywhere

  @override
  Object? get widget => null;
}

extension on NavSpec {
  StackEntry entry(Enum screen, [Object? id]) =>
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
      expect(() => NavSpec({S.home({S.friends.cycled})}),
          throwsStateError);
    });

    test('keep/forget set per-screen liveness when parked', () {
      final s = NavSpec({
        S.home({S.profile.keep({S.friends, S.review.forget()})})
      });
      expect(s.keeps, contains(S.profile));
      expect(s.forgets, contains(S.review));
      expect(s.retains(S.home), isTrue); // tab has a keep → retained when parked
      expect(s.keptWhenParked(S.home), isFalse); // above the keep → freed
      expect(s.keptWhenParked(S.profile), isTrue); // the keep itself → live
      expect(s.keptWhenParked(S.friends), isTrue); // under the keep → live
      expect(s.keptWhenParked(S.review), isFalse); // forget carves it back out
    });

    test('redundant keep/forget is a build error', () {
      // keep under keep with no forget between
      expect(() => NavSpec({S.home.keep({S.profile.keep()})}), throwsStateError);
      // forget with no keep above it
      expect(() => NavSpec({S.home({S.profile.forget()})}), throwsStateError);
      // forget under forget with no keep between
      expect(
          () => NavSpec({S.home.keep({S.profile.forget({S.friends.forget()})})}),
          throwsStateError);
    });

    test('a failed build never poisons the next construction', () {
      expect(() => NavSpec({S.home({S.friends.cycled})}),
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

  group('graft (cross-enum subtree)', () {
    test('splices a foreign subtree into the native tree as one graph', () {
      final s = NavSpec({
        S.home({graft(Sub.tree())})
      });
      // The grafted screens live under the native parent, in one unified spec.
      expect(s.canonical[Sub.shop]!.parent!.screen, S.home);
      expect(s.canonical[Sub.catalog]!.parent!.screen, Sub.shop);
      expect(s.trunkOf(Sub.catalog), S.home);
    });

    test('navigates across the graft edge', () {
      final s = NavSpec({
        S.home({graft(Sub.tree())})
      });
      // home -> shop (a cross-enum edge) -> catalog
      final r = resolveGo(s, [s.entry(S.home)], Sub.shop, null);
      expect(r.pushes.single.screen, Sub.shop);
      final r2 = resolveGo(
          s, [s.entry(S.home), s.entry(Sub.shop)], Sub.catalog, null);
      expect(r2.pushes.single.screen, Sub.catalog);
    });
  });

  group('shared screens (refs collapse to the owner)', () {
    test('a ref is rewritten to its same-named owner', () {
      final s = NavSpec({
        Own.home({Own.profile, graft(Ref.tree())})
      });
      expect(s.canonical.containsKey(Ref.profile), isFalse); // ref erased
      // the ref placement under shop now points at the owner value
      expect(s.canonical[Ref.shop]!.children.single.screen, Own.profile);
      // placed under home AND (via the ref) under shop → multi
      expect(s.isMulti(Own.profile), isTrue);
    });

    test('two owners of one name is a build error', () {
      expect(
          () => NavSpec({
                Own.home({Own.profile, graft(TwoOwners.profile)})
              }),
          throwsStateError);
    });

    test('a ref with no owner is a build error', () {
      expect(() => NavSpec({Dangling.ghost()}), throwsStateError);
    });
  });

  group('structure signature', () {
    test('is sibling-order independent', () {
      final a = NavSpec({S.home({S.settings, S.language})}).structureSignature;
      final b = NavSpec({S.home({S.language, S.settings})}).structureSignature;
      expect(a, b);
    });

    test('re-parenting changes the signature', () {
      final a = NavSpec({S.home({S.language}), S.settings()}).structureSignature;
      final b = NavSpec({S.home(), S.settings({S.language})}).structureSignature;
      expect(a, isNot(b));
    });

    test('reflects keep and again flags', () {
      expect(NavSpec({S.home.keep({S.language})}).structureSignature,
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
      // profile<a> -> review<a> -> back to profile<a> via the review header
      final s = S.spec();
      final stack = [
        s.entry(S.home),
        s.entry(S.profile, 'a'),
        s.entry(S.review, ('x', 'a')),
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
      // up<a>/review<a>/up<a> + review<a> -> period 2: pop back to review<a>
      final s = S.spec();
      final stack = [
        s.entry(S.home),
        s.entry(S.profile, 'a'),
        s.entry(S.review, ('x', 'a')),
        s.entry(S.profile, 'a'),
      ];
      final r = resolveGo(s, stack, S.review, ('x', 'a'));
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
      final cycled = NavSpec({S.profile({S.review({S.profile.cycled})})});
      final stacked = NavSpec({S.profile({S.review({S.profile.stacked})})});
      List<StackEntry> stk(NavSpec s) => [
            s.entry(S.profile, 'a'),
            s.entry(S.review, ('x', 'a')),
            s.entry(S.profile, 'a'),
            s.entry(S.review, ('x', 'a')),
          ];
      final c = resolveGo(cycled, stk(cycled), S.profile, 'a');
      expect(c.popCount, 1); // folds back to the previous occurrence
      expect(c.pushes, isEmpty);

      final s = resolveGo(stacked, stk(stacked), S.profile, 'a');
      expect(s.popCount, 0); // keeps the stack
      expect(s.pushes.single.screen, S.profile);
    });

    test('stacked pushes a fresh instance even for an exact duplicate of the top', () {
      final stacked = NavSpec({S.profile({S.profile.stacked})});
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
      expect(resolvePop([s.entry(S.home)], S.review), isNull);
    });
  });

  group('links (link-world boundary)', () {
    test('.links makes a LinkBranch carrying link grammar', () {
      final b = S.home.links();
      expect(b, isA<LinkBranch>());
      expect((b as LinkBranch).node, isNotNull);
    });

    test('NavSpec skips a root LinkBranch — links seed no nav screen', () {
      final spec = NavSpec({
        S.home({S.feed}),
        S.home.links(), // root link branch → ignored by nav
      });
      expect(spec.canonical.length, 2); // home, feed only
      expect(spec.canonical.containsKey(S.home), isTrue);
      expect(spec.canonical.containsKey(S.feed), isTrue);
    });

    test('a LinkBranch nested inside a .call placement is also skipped', () {
      final spec = NavSpec({
        S.settings({S.language, S.home.links()}), // nested link branch
      });
      expect(spec.canonical.length, 2); // settings, language — link skipped
    });
  });
}
