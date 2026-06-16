## 0.8.0

- **Roots can carry ids.** `go(root, id)` now seeds (or reseeds, when the id differs) the root scope with that id instead of dropping it, and `NavGraph(initialId: …)` seeds the initial root. An id-bearing root is identified by its id (entering it with a different id reseeds; id-free roots pass null and resume their parked stack unchanged). This closes the gap where an `inherit` chain rooted at an id-bearing root couldn't stamp the root's id — `inherit(home)`-style chains and the kick-start rescue from a root source now work.

## 0.7.0

- **`inherit` — a placement's id is structurally an ancestor's.** `ad({editAd.inherit(ad)})` declares `editAd.id == ad.id`; the generated chained push verb takes no id (`Screen.on(.ad)?.goEditAd()` / `goAd(id).goEditAd()`) and reads the live ancestor id, so the two ids can never diverge. Runtime adds a no-op `inherit(S ancestor)` marker on `ScreenNodeBase`.
- **Breaking: tree sets are now `Set<TreeNode<S>>`.** A new `sealed class TreeNode<S>` is the grammar set element type; the spec enum implements it via the `ScreenNode` mixin, and `cycled`/`stacked` now return a first-class `_BackEdge<S>` instead of the screen. This (a) makes chaining after a back-edge (`.cycled.inherit(…)`) a compile error, (b) rejects foreign/other-graph elements in a tree set, and (c) removes the per-family stash for back-edges. Tree literals are unaffected (the element type is inferred); only code that named the `Set<S>` root/children types directly needs `Set<TreeNode<S>>`.
- Pairs with canon_generator ^0.8.0 (adds `Screen.on(.parentOf.x)?.go(…)` scope-agnostic push).

## 0.6.0

- **Breaking: `ScreenNode` now dictates the widget.** The grammar engine stays pure-Dart by being generic over the widget type (`mixin ScreenNodeBase<S extends ScreenNodeBase<S, W>, W extends Object> on Enum { W get widget; ... }`), and the Flutter layer binds it: `typedef ScreenNode<S extends ScreenNodeBase<S, Widget>> = ScreenNodeBase<S, Widget>`. Consumers now write the **one-arg** `enum _Screens with ScreenNode<_Screens>` and must provide `final Widget widget`. The vestigial id type param `I` is dropped (per-screen id types come from the generator, not the mixin). Engine generics bound `<S, Object>` and accept consumer `<S, Widget>` via covariance.

## 0.5.0

- Add `NavGraph.observe(fn)` — a side-effect listener fired after each navigation commits (new top settled, before its transition animates), with `(from, to)` screens; returns a disposer. Pure observation (no veto/reroute), meant to be wired where state lives (e.g. a provider). The generator surfaces it typed as `Screen.observe((Screen from, Screen to) {...})`. The "after transition settled" phase is deferred to the origin collaboration.

## 0.4.0

- Self-pop: `popToXx` now reaches the *previous* occurrence of the screen you're on (`resolvePop` skips the current top) instead of no-opping, and it's chainable through a cycle — `popToProfile().popToProfile()` steps back two. Cycle-member pops are now on union navs too so chains keep a handle that still exposes them. (Relative/absolute "by n / at depth n" are just chaining + the `depth` getter — no extra verbs.) Generator no longer emits an unused `_endsWith` helper for trees that don't use `.under`.

## 0.3.0

- Cycle navigation: `NavGraph.countOf(screen, [id])` for cycle depth, a `depth` getter on cyclic nav handles (`Screen.at case XNav(:depth) when depth > 1`), the one-shot `Screen.on(.x([id]).depth(n))` exact-match gate (compile-gated to cyclic screens), and throwing cycle-member `popToX` verbs guarded by those depth checks.

## 0.2.1

- Handle verbs (`goX`/`go(Hop)`) are edge-required: a target unreachable from the live top throws instead of silently teleporting via the canonical fallback, and guaranteed `pop`/`popTo` throw when impossible — both release-active (replacing debug-only asserts). Stale-but-still-legal navigations still resolve; the global `Screen.goX` teleport is unchanged.

## 0.2.0

- Stale-codegen guard: `Screen.isCodegenFresh` + a boot-time assert flag a tree that was re-parented without regenerating.
- Replace the `again` back-edge with `cycled` (folds a completed duplicate cycle) and `stacked` (stacks a fresh instance, preserving history).

## 0.1.0

- Initial release.
