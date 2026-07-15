# canon

**An application runtime context specification.** You declare your app's navigable runtime contexts as one grammar tree; canon projects that spec into navigation, the URL, and state. Everything else hangs off that essence as a property: *compile-safety* is how the projection is realized, and *identity*, when a context has one, is a property **of the context** — ambient within it, read from the runtime, never threaded through application code.

canon is pure Dart. It carries the grammar tree, the navigation state machine that folds it, the entity and identity spaces, and the URL/link codec — one model that runs anywhere Dart does: a server, shared code, a headless test. The transitions the grammar declares are the only transitions that exist; an illegal route is rejected when the tree is *built*, not when a user hits it.

Built for the AI-authorship era: a machine can only emit legal navigation, and a human audits the **entire nav space** at a glance in one small spec.

## What depending on canon gives you

- **The grammar tree** — `ScreenNodeBase` / `LinkNode` enum rows, the placement DSL (`.keep`, `.forget`, `.inherit`, `.again`, `.links`, `graft`), query/fragment declarations.
- **The navigation state machine** — `NavGraph`: an in-memory stack per trunk, folded by a pure reducer from `NavOp` facts.
- **The identity space** — `IdNode`: named identities, each carrying its URL codec; composites compose rows.
- **The entity space** — `EntityNode` + `EntityGraph`: what exists, and who owns whom.
- **The link layer** — `LinkSpec` / `LinkMatcher`: a strict, bidirectional URL ↔ route codec.
- **Re-exports** — `canon_codec` (the codecs) and `regent` (the ledger engine), so one import carries location, state, and identity.

The `@canon` annotation — the one spec mark every canon enum wears — is declared here, so a spec library needs no other dependency.

## The grammar tree

One enum declares the screens; a static builds the tree. Edges in the tree are the legal moves — a transition that isn't an edge doesn't exist in the model:

```dart
import 'package:canon/canon.dart';

enum Shop with ScreenNodeBase<Shop, Object> {
  storefront, search, orders, category, product, reviews, checkout;

  // The presentation payload is opaque to the model; a pure consumer
  // binds W to anything.
  @override
  Object get widget => name;

  static Shop _product() => product({
        reviews,
        product.again, // a related product — same screen, a fresh frame
      });

  static final graph = NavGraph({
    storefront.keep({category({_product()})}),
    search({_product()}),
    orders({checkout}),
  });
}
```

A row placed with children is `name({...})`; a bare row is a leaf. The set literals *are* the grammar: `product` is reachable under both `storefront` (via `category`) and `search`, `checkout` only under `orders`. The three top-level entries are **trunks** — the roots the stack can switch between.

The built graph is inspectable:

```dart
final trunks = Shop.graph.spec.trunks;      // storefront, search, orders
final stack = Shop.graph.stack;             // the live entries, bottom to top
final off = Shop.graph.observe((from, to) { /* post-commit, no veto */ });
```

Malformed grammar throws at construction — `.again` with no same-screen ancestor, two owners of one name, a redundant `.keep`/`.forget` that flips nothing. A failed build never poisons the next construction.

## The core: transitions are legal moves

Elsewhere, routes are strings and ids are stringly-typed map lookups — a typo compiles and crashes at runtime, a wrong key is a silent `null`. In canon the nav space is *closed*: every reachable position is an edge walk from a trunk, and a target with no edge from the live position isn't a crash — the model resolves the canonical path to it (filling id-free intermediates) or reports the missing edge as a diagnostic at the moment the tree could have declared it.

Navigation itself is a fold. A `go(screen, id)` fact resolves against the live stack down a fixed ladder:

1. **The universal tap** — navigating to the exact current top (same screen *and* id) is a no-op; a declared `.again` edge opts out and pushes a fresh frame instead.
2. **A live edge** — the target is a child of the current top: one push. An `.again` back-edge pushes a new occurrence of the same screen, keeping everything beneath.
3. **The canonical path** — no live edge: the model reuses the longest common prefix of the live stack, pops what's above it, and pushes the canonical route to the target. A trunk switch is the degenerate case — pop all, push the new trunk.

`pop` is the inverse: one entry, or pop-until-nearest-target (the target survives); popping a trunk is not a move, it's a `null` — the model never throws for "can't pop", it makes the impossibility a value.

Ids ride the stack entries, not the grammar: the same `product` node holds `'p1'` in one frame and `'p2'` in the next, and the no-op-tap / fresh-frame distinction compares both screen and id.

## Inherit: an id that's provably the parent's

Placing a screen as `x.inherit(parent)` declares that *in this placement* its id is always the parent's — there is no slot to inject a different one, so the classic wrong-entity bug is unrepresentable, not caught:

```dart
NavGraph({
  Shop.orders({
    Shop.product({
      // editReview's id is always THIS product's review context — the
      // edge carries no independent id slot.
      Shop.reviews.inherit(Shop.product),
    }),
  }),
});
```

Inherit is per-placement — the same screen placed elsewhere without that ancestor takes its own id — and transitive: chains flatten to the ultimate id source. An inheriting trunk is a build error (there is nothing above it to inherit from), and inherit composes with `.again`: the id lock rides the back-edge.

## Recursion: again

`product.again` declares that a screen may follow itself — a related product from a product, each visit a **fresh** frame with its intermediate frames kept. The one universal fold stays: navigating to the exact current top is a no-op — and a declared `.again` edge opts out even of that. Anything cleverer (fold-to-ancestor, cycle collapse) is yours to wire with checks on the live stack; repeated blocks never fold implicitly.

## State retention: keep / forget

`.keep` / `.forget` decide whether a scope's stack **survives parking its trunk** (switching to another trunk) and coming back. Retention is scoped: everything under a `.keep` is live while parked, a nested `.forget` carves a subtree back out, and a `.keep` that flips nothing (a keep under a keep, a forget with no keep above) is a build error — a no-op annotation won't construct. Retention applies only to the trunk switch; a move to an ancestor *within* the scope pops the screens above as normal.

## View-state: query and fragment

A screen declares typed, nullable **view-state keys** mirrored into the URL's `?query` / `#fragment`. Keys come from a `QueryKeyBase` enum — `key(codec)` binds a value, a bare key is a boolean flag:

```dart
enum View with QueryKeyBase { text, sort }
```

and ride the tree as `search.query({View.text(Codec.string)})` / `.fragment({...})`. The mirror is *historyless* — view-state changes replace, they never flood back-history.

Fragments can also be structured **paths**. `fragmentRoots` declares the legal shapes; decode is strict — any bad position rejects the whole fragment — and encode refuses an illegal write:

```dart
// #deals · #<slug> · #<slug>/thumb · #<slug>/gallery/<int>/zoom
final roots = fragmentRoots({
  Codec.literal('deals'),
  Codec.string / {Codec.literal('thumb'),
      Codec.literal('gallery') / (Codec.integer / {Codec.literal('zoom')})},
});

decodeFragmentPath(roots, 'p42/gallery/3/zoom'); // ['p42', 'gallery', 3, 'zoom']
decodeFragmentPath(roots, 'p42/nope');           // null — strict
encodeFragmentPath(roots, ['p42', 'thumb']);     // 'p42/thumb'
```

A trailing `:~:` text directive is user-agent territory and is stripped before decoding.

## Codecs (id types)

An id is a **value-witness**: a codec's `T` is the id's static type, and the codec itself is for restoration and deep links — a strict string ↔ `T` round-trip whose `decode` returns `null` to reject malformed input:

`.string .raw .uuid .username .email .integer .number .date .enumValues(...) .record2/.record3(...) .csv(...) .literal(...)` — or any `const` class implementing `Codec<T>`. Codecs concatenate: `Codec.integer + Codec.literal('_thumb')` decodes `2_thumb` to `2` — an affix carried by the codec, not the URL structure.

## The identity space: IdNode

Identities graduate from scattered codec arguments to a **declared space**: one enum, each row a named identity carrying its URL codec. Composites compose rows into a record key:

```dart
@canon
enum Ids with IdNode {
  author(.uuid),
  product(.uuid);

  const Ids(this.codec);
  @override
  final Codec codec;

  // A review is keyed by both.
  static const IdNode review = .compose(product, author);
}
```

Every space that needs a key — a screen, an entity, a store — points at the same row, which is what lets data inject by nav location: one identity, declared once.

## The entity space: EntityNode

What exists, and who owns whom. Each row binds an entity type to its id node; the graph declares **ownership** — a child's state lives inside its root's, and an unlisted row is a root:

```dart
@canon
enum Entities with EntityNode<Entities> {
  product(Product, Ids.product),
  author(Author, Ids.author),
  review(Review, Ids.review),
  comment(Comment, Ids.comment);

  const Entities(this.type, this.key);
  @override
  final Type type;
  @override
  final IdNode key;

  static final graph = EntityGraph({
    author,
    product({review({comment})}),
  });
}
```

`graph.roots`, `graph.isRoot(x)`, `graph.ownersOf(x)` derive from the tree; one child kind may be owned by several parent kinds, and declaring a row both root and owned is a build error — nothing is declared twice, so the trees can never disagree.

## Links: URL ↔ route, both directions

Every screen is addressable, and `.links()` branches add **resolve-only** leaves — a URL shape with no screen behind it yet (`/author/<username>`). A links-only surface needs no presentation at all — a fieldless `LinkNode` enum is a complete declaration, what a server authors:

```dart
enum Links with LinkNode<Links> {
  shop, product, review;

  static final graph = NavGraph({
    shop({product({review})}),
  });
}
```

Underneath, `LinkSpec` / `LinkMatcher` are the codec: a tree of static edges and typed slots per domain, matched with committed fallthrough (a static beats a slot; a committed branch never backtracks), strict on the host boundary (no prefix spoofing), and bidirectional — `print(parse(url))` is the identity on canonical URLs:

```dart
final products = SegBuilder.forScreen('product')..children = {slot(Codec.uuid)};
final authors = SegBuilder.forScreen('author')
  ..children = {slots({Codec.literal('me'), Codec.uuid, Codec.username})};
final matcher = LinkMatcher(
    LinkSpec([DomainNode('https://example.com', linkRoot({products, authors}))]));

final r = matcher.parse('https://example.com/author/ada')!;
// r.template == 'author/*', r.path == ['ada'], r.branches == [2] — which
// union branch matched; printRoute re-encodes the same branch.
```

Query params are part of the match: typed keys, flags, lists preserving occurrence order, and mandatory gates — `requireAllOf` / `requireOneOf` make a URL that's meaningless without its query (an OAuth callback) simply not match. Unmodeled keys are ignored on parse and dropped on print.

## The ledger: the regency

canon re-exports `regent`, the state engine the model is designed to sit on. State is a **journal of sealed facts** folded by pure functions — `dispatch(fact)` is the app's only verb. A regency is a const set of regents where set order is traversal order: **store** rows are pure readers folding what passes; **guard** rows are pure judges deciding what every row below sees — drop, pass, rewrite, or fan out — replayable by construction because they read the ledger's own state.

Navigation itself can be ledger-owned: with a nav row, every move dispatches a `NavOp` fact through the queue — auth walls and redirects are gates, the stack is a pure fold (`navReduce`), and the journal carries the session whole: state, writes, movement. Replay it and the app is reproduced, not approximated. Without the row, navigation folds locally through the same pure engine — a grammar-only consumer never sees the ledger at all.

Order-independence is a law you run: `replay(app, order)` folds the whole graph synchronously, and cross-source races must converge. See regent's own documentation for the full model.

## Guarantees

- **Build-time:** one owner per screen name; `.inherit` must target a real ancestor; `.again` needs a same-screen ancestor; `.keep`/`.forget` must genuinely flip retention; a name is a screen *or* a `.links` branch at a given position, never both; a failed construction never poisons the next.
- **Model-time:** the nav space is closed — every reachable position is an edge walk from a trunk; navigation resolves down one fixed ladder (tap fold, live edge, canonical path) and a missing edge is a diagnostic, not a crash; pop at a trunk is a `null`, never a throw.
- **Codec strictness:** every id, query value, fragment path, and link is a validating round-trip — malformed input decodes to `null`, an illegal write encodes to `null`, and `print ∘ parse` is the identity on canonical URLs.
- **One declaration:** screens, identities, entities, and links reference the same rows; nothing is stated twice, so the projections can never disagree.

The payoff: the spec at the top of a grammar file *is* the complete, auditable nav space. A model can only emit legal navigation, and a human reviews every reachable route at a glance.

## Install

```yaml
dependencies:
  canon: ^0.31.0
```

One import — `package:canon/canon.dart` — carries the grammar, the nav model, the identity and entity spaces, the link codec, the codecs, and the ledger engine.
