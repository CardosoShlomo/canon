## 0.18.1

- README: sharpen positioning and document the unified web/mobile model — `Screen.manager`, the `Url`→`Place`/`Link`/`RootUrl` resolver, and `url.domain`.

## 0.18.0

- Full browser back/forward history on web: multi-entry History API, refresh-survival, and a floor model with returnable (`anchor`) vs bounce-exit (`passthrough`) roots.
- Grammar `root` → `trunk`; the base/initial concept claims `root` (`root:` boot widget, `Screen.rootUrl`, `Screen.root` controls, `BootScreen.root`). Breaking.

## 0.17.0

- Single navigation resolver: external URLs / deep-links (web address bar + mobile app-links) route through one resolver via `setNewRoutePath`, with a consume-once cold-start replay.
- Web history honors REPLACE mode (first-commit-out-of-boot + `Screen.replace.*`), restores back/forward silently (forward stack preserved), and makes re-navigating to the current top an idempotent no-op.
- URL mirrors the TOP screen's forward grammar path only — `.stacked`/`.cycled` back-edges add stack depth (blob), never URL segments.
- `parseLink` accepts path-only URLs instead of throwing; the boot URL is captured eagerly for `Screen.initialUrl`.

## 0.16.0

- Reactive, surgical view-state reads: `context.on` / `context.at` and `Query.of` / `Fragment.of` rebuild only on the keys they reference.
- Sealed `AnyPlacement` foundation for `Screen.current` / `on` / `at` and `surface()`.
- Nav-mirror + link URL building: new `encodeNavUrl`, and `encodeLink` now carries `?query` / `#fragment`.
- Widget-form link id leads its union (`[id, …declared]`).
- Sim-safe `popTo`; screen lifecycle callbacks removed. Requires `canon_codec ^0.1.3`.

## 0.15.1

- Docs: `Screen.go(Hop)` returns a `KickstartNav` (`.at` narrows to the landed target) as of canon_generator 0.19.0.

## 0.15.0

- `pageOf` and `observers` are now optional (`pageOf` defaults to `MaterialPage`).
- Removed the unused `maybePop`; engine `go`/`pop`/`forget` are now `@internal` — navigate via the generated typed verbs.

## 0.14.0

- `Screen.manager()` restoration is now always on by default (`restorationId` defaults to `'nav'`); pass it only to override the storage key. Drop-in: existing `manager()` calls keep working, `manager()` with no args now restores.

## 0.13.0

- Add `Screen.manager()` / `NavGraph.manager()` — a standalone nav host for `MaterialApp(home: ...)`, no Router/RouteInformation channel (URLs/deep-links never drive the stack). Owns system back; with a restorationId, persists/restores the snapshot. `Screen.delegate` (Router/MaterialApp.router) stays for URL/web integration.

## 0.12.0

- **Breaking: ids are read only through the typed `context.idOf(...)`.** `ScreenScope` is now `@internal` and canon wraps every page in it itself, so `pageOf` no longer wraps it and `PageCtx.entry` is gone (use `PageCtx.screen`). The raw `Object? id` is never exposed to screen code; the generated `context.idOf(ScreenId.x)` (id-bearing screens only) is the single sanctioned, non-null reader.
- `ScreenScope.of(context)` now returns the screen `Enum`; `ScreenScope.idOf<T>(context, spec)` is the internal typed seam the generated extension delegates to.
- Pairs with canon_generator ^0.15.0 (emits `ScreenId<I>` + the delegating extension).

## 0.11.0

- **Built-in state restoration.** `NavGraph.toState()` snapshots the full multi-scope stack (restoration-serializable) and `restore(state)` rebuilds it — best-effort: any mid-stack failure (illegal edge, unknown screen, or a token its codec rejects) truncates there, dropping that screen and everything above it, keeping the valid prefix. A stale-graph snapshot is rejected outright. No codegen, no wiring.
- **Id codecs on the screen.** `ScreenNodeBase` exposes `Codec? get id` (default null); declare `final Codec? id;` on the enum and the engine round-trips ids for restoration by reading the codec directly.
- **Re-exports `Codec`** from the new `canon_codec` package, so `package:canon/canon.dart` is the only import needed for the nav DSL *and* id codecs.

## 0.10.0

- **Breaking: engine erased to `Enum`** so one graph can hold screens from several enums. `NavGraph<S, I>` → `NavGraph<I>`, `PageCtx<S>` → `PageCtx`, `pageOf` is now `(Widget widget, PageCtx ctx, LocalKey key)` (the resolved widget; the screen + id are in `ctx.entry`), and `observe` takes `(Enum from, Enum to)`. The authoring DSL stays typed per family.
- **`graft` — split a large graph across enums.** `graft(Sub.subtree)` mounts another screen family's subtree into the tree (the one explicit cross-family edge); the runtime splices it into one virtual tree, so the surface is blind to the split.
- **`keep`/`forget` — live content across tab parks.** `screen.keep({...})` keeps a placement and its subtree mounted when its tab parks (content-swapped, not rebuilt); `forget()` carves a region back out. `NavGraph.forget(keep)` frees a parked keep.
- **Shared screens via refs.** `SubScreenNode`'s widget is now optional: a null-widget row is a ref that collapses to its same-named owner (exactly one owner per name, no dangling ref), so a screen owned in one enum can be referenced in-family from another for `inherit`/`cycled`.

## 0.9.1

- Fix: a `.stacked` back-edge now pushes a fresh instance even when the target is an exact duplicate of the current top (e.g. `userProfile(x)` from `userProfile(x)`). The universal p==1 exact-duplicate no-op no longer applies to non-collapsing edges, matching `.stacked`'s "fresh instance every revisit" semantics. Collapsing/`.cycled` and forward edges keep the duplicate guard.

## 0.9.0

- **Breaking: `initial:` is now a typed `InitialScreen`.** `NavGraph` is `NavGraph<S, I extends InitialScreenBase<S>>` and `initial` takes an `I` — the generated `InitialScreen` (e.g. `NavGraph<_Screens, InitialScreen>(initial: .home.settings.about)`). It seeds the entire root..target chain, so the start can be any reachable stack, not just a root. Only an `InitialScreen` is accepted, so a navigating `Screen.goX` or a live-stack `Screen.on(...)` can't be passed as the initial.
- **Removed `initialId`** (shipped in 0.8.0) — superseded by the typed `initial`. An id-bearing initial is expressed as `initial: .someRoot(id)` / a chain.

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
