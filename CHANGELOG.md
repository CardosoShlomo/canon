## 0.3.0

- Cycle navigation: `NavGraph.countOf(screen, [id])` for cycle depth, a `depth` getter on cyclic nav handles (`Screen.at case XNav(:depth) when depth > 1`), the one-shot `Screen.on(.x([id]).depth(n))` exact-match gate (compile-gated to cyclic screens), and throwing cycle-member `popToX` verbs guarded by those depth checks.

## 0.2.1

- Handle verbs (`goX`/`go(Hop)`) are edge-required: a target unreachable from the live top throws instead of silently teleporting via the canonical fallback, and guaranteed `pop`/`popTo` throw when impossible — both release-active (replacing debug-only asserts). Stale-but-still-legal navigations still resolve; the global `Screen.goX` teleport is unchanged.

## 0.2.0

- Stale-codegen guard: `Screen.isCodegenFresh` + a boot-time assert flag a tree that was re-parented without regenerating.
- Replace the `again` back-edge with `cycled` (folds a completed duplicate cycle) and `stacked` (stacks a fresh instance, preserving history).

## 0.1.0

- Initial release.
