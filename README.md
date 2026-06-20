# canon

Compile-safe Flutter navigation generated from **one grammar tree**. The transitions you're *allowed* to make are the only methods that exist — an illegal route is a **compile error**, not a runtime crash.

Built for the AI-authorship era: a machine can only emit legal navigation, and a human audits the **entire nav space** at a glance in one small spec.

## The whole app, on one screen

```dart
import 'package:canon/canon.dart';
part 'screen.nav.dart';

@screens
enum _Screens with ScreenNode<_Screens> {
  home(HomeScreen()),
  search(SearchScreen()),
  messages(MessagesScreen()),
  profile(ProfileScreen()),
  user(UserScreen(), .uuid),
  post(PostScreen(), .uuid),
  editPost(EditPostScreen(), .uuid),
  comment(CommentScreen(), .uuid),
  thread(ThreadScreen(), .uuid),
  settings(SettingsScreen());

  const _Screens(this.widget, [this.id]);
  @override final Widget widget;
  @override final Codec? id;

  // A profile: this user's posts, and links to other users (followers).
  static _Screens _user() => user({
    post({ comment, user.cycled }),
    user.stacked,                    // tap a follower → another profile, fresh frame
  });

  static final graph = NavGraph<InitialScreen>({
    home.keep({ _user() }),
    search.keep({ _user(), comment }),
    messages.keep({ thread({ _user() }) }),
    profile.keep({
      post({ editPost.inherit(post), comment }),  // here, editPost's id is always this post's
      settings,
    }),
  }, initial: .home);
}
```

A row is `name(WidgetConst())` or `name(WidgetConst(), idCodec)`. One library-private `@screens` enum, one `NavGraph`, `part 'screen.nav.dart';` — that's the whole grammar. Codegen turns this tree into a typed `Screen` facade whose methods *are* its edges. Read this section and you've read the app's navigation; everything below maps to a line in it.

## The core: typed transitions are legal moves

**Without canon** — routes are strings, ids are stringly-typed map lookups:

```dart
context.go('/messages/thraed/$id');     // typo compiles, crashes at runtime
final id = state.params['treadId'];     // wrong key → null → blank screen
```

The typo, the wrong key, the wrong id type — all invisible until a user hits them.

**With canon** — the transition is a generated method that only exists where the edge exists:

```dart
Screen.goThread(id);                    // thread is single-placement → kick-start exists
```

The typo **cannot exist**: there is no `goThraed`. `Screen.goThread()` with no id is a compile error (thread is id-bearing). `Screen.goThread(42)` is a compile error (its id type is `String`). There is no `Screen.goComment` at all — `comment` has two parents, so it has no unambiguous kick-start. **Illegal routes aren't caught; they're unrepresentable — not a string to mistype, not a map to mis-key.**

And `goX` is **non-destructive by construction** — a deep link or push extends from your live position, it never nukes the back stack. Bug class deleted.

## Two ways to move

**Kick-start** — from anywhere; emitted *only* when the target is reachable single-placement with the ids you supply.

```dart
Screen.goHome();
Screen.goSettings();
Screen.goThread(threadId);
```

For a *dynamic* kick-start, `Screen.go(Hop.x)` takes a ternary and returns a `KickstartNav` — `.at` narrows it to the exact screen it landed on (exhaustive switch).

**Surgical-chain** — continue from a live position; ids already on the stack are reused. `Screen.on(.path)` returns a placement (a typed `…Nav`) or `null`, each step offers only satisfiable children, and a whole path commits as **one** transition:

```dart
Screen.on(.search)?.goUser(id);                  // .user matches ANY live user
Screen.on(.user(id))?.goPost(postId);            // .user(id) pins one occurrence
Screen.goHome().goUser(authorId).goPost(postId); // chain disambiguates: post lands under THAT user
```

**Broad reach** — a kick-start's reach extends inward: a *single-placement* id screen gets its `goX(id)` on every ancestor whose path down to it crosses no unrelated id screen (id-free intermediates auto-fill), so an ancestor jumps straight to a descendant supplying just the one id it needs. (`post` is multi-placement, so there's no broad `goPost` — only the direct-child edge above; `editPost` below is the real broad-reach case.)

## Inherit: an id that's provably the parent's

`editPost` is an ordinary `.uuid` screen. Placing it as `editPost.inherit(post)` declares that *in this placement* its id is always `post`'s — which buys two things at once:

- **Sugar** — you never re-pass that id; it's taken from the live `post` (the edge verb has no id param).
- **Guarantee** — there is no slot to inject a *different* id, so the compiler proves `editPost`'s id is 100% this `post`'s. The classic bug — opening an editor on the wrong entity — isn't caught at runtime, it's unrepresentable.

Inherit is per-placement: put `editPost` somewhere without `post` as an ancestor and it's just a normal id screen taking its own id. Transitive — it flattens to the ultimate id source.

```dart
Screen.goEditPost(postId);                          // kick-start: stamps post AND editPost
Screen.on(.post)?.goEditPost();                     // already on post → nothing to pass
Screen.on(.profile)?.goPost(postId).goEditPost();   // give post the id; editPost inherits
Screen.on(.profile)?.goEditPost(postId);            // broad reach: profile → editPost, one id, both pushed
assert(context.idOf(.editPost) == context.idOf(.post)); // inside editPost: always holds — the guarantee
```

## parentOf: push onto whoever hosts you

`comment` has two distinct parents (`post`, `search`). `parentOf` pushes onto whichever currently hosts you, with no branching on where you are:

```dart
Screen.on(.parentOf.comment)?.goComment(id);
Screen.on(.parentOf);                       // compile error — target mandatory
Screen.on(.parentOf.home);                  // compile error — home is a root, it has no parent
```

## Recursion: stacked vs cycled

A profile links to other profiles, and a post links back to its author. Two distinct recursions, both explicit in the tree:

- `user.stacked` — drill-in: push a **fresh** instance, keep intermediate frames (follower → follower → follower).
- `user.cycled` — exactly `stacked`, plus one rule: it won't stack a second identical copy of a cycle. If a move would repeat a run of frames (same screens **and** ids) back-to-back, canon drops the repeat and returns you to the existing run; any differing id breaks the match, so it just stacks.

Cyclic screens expose `depth` (live occurrence count); `.depth(n)` pins one:

```dart
if (Screen.at case HomeUserNav(:final depth)) { ... }   // how deep in the chain
Screen.on(.user.depth(2))?.popToUser();                 // act on a specific occurrence
```

## Back

`Screen.canPop` is `null` iff you're at a root. `Screen.pop()` is sugar for `Screen.canPop?.pop()` — it pops if it can and returns where you landed (or `null` at a root), never throws. That destination is a union over every non-leaf placement (anywhere you could land), so narrow it with `.at`:

```dart
final landed = Screen.pop();        // null at a root
switch (landed?.at) { /* one case per non-leaf placement — exhaustive */ }
```

`Screen.on(...)`, `Screen.at`, and every move return a **placement** — a typed `…Nav` like `ThreadNav` or `HomeUserNav`. It's a transient cursor: each move returns the **next** placement and you step from that.

```dart
Screen.goThread(threadId).goUser(userId);   // chain off each returned placement
```

A placement is edge-required and single-use — a spent or stale one throws instead of acting from the wrong spot:

```dart
final thread = Screen.goThread(threadId);
thread.goUser(userId);                       // moved off thread
thread.pop();                                // throws — thread is already spent
```

```dart
final thread = Screen.goThread(threadId);
await save();                                // navigation may move on during the gap
thread.goUser(userId);                       // throws IF user is no longer a live edge from here
```

Where a screen has 2+ children or ancestors, `go(Hop.x)` / `popTo(Pop.x)` take a ternary for dynamic branching — `go(busy ? Hop.user(a) : Hop.comment(c))` — returning the least-common placement type; chain off a named verb when you need a specific one.

## Inspect position — typed, exhaustive

**The bug:** `"is route X active?"` by string/regex compare.

**Foreclosed:** `Screen.at` is the exact current placement (never null). `Screen.on(.user)` is the **union** of `user`'s placements, `null` when inactive; `.at` narrows it to a sealed switch — a new placement you forget to handle **won't compile**:

```dart
if (Screen.at case HomeUserNav n) ...           // exact current placement

switch (Screen.on(.user)?.at) {        // no default — add a placement and this won't compile
  case HomeUserNav():            ...
  case SearchUserNav():          ...
  case MessagesThreadUserNav():  ...
  case null:                     ...   // not on a user
}
```

`.under` steps one level outward; `Screen.stack` exposes `.current`, `.currentId`, `.screens`, `.reachable`, and `.tab` (the active root — the bottom of the stack).

## Read a screen's own id

**The bug:** a mirrored `currentUserId` provider, or id threaded through every constructor — two sources of truth that drift.

**Foreclosed:**

```dart
final userId = context.idOf(.user);   // typed, never null for an id-bearing screen
context.idOf(.home);                  // compile error — home has no id
```

No `InheritedWidget`, no mirror, no route-param threading. (When one widget backs 2+ id-bearing screens, codegen emits a sealed `Screen.<widget>Id(context)` resolver you switch exhaustively — not needed in this tree.)

## State retention

`keep` / `forget` decide whether a scope's stack **survives leaving it for another root** (a kick-start to a different family) and coming back — build-time checked to actually flip inherited state, so a no-op annotation won't compile:

```dart
home.keep({ _user() })   // jump to another root and back → home's stack is intact
child.forget()           // this subtree is dropped, rebuilt fresh on return
```

Retention applies only to that root switch — a `popTo`/`go` to an ancestor *within* the scope pops the screens above as normal; they're gone.

## Codecs (id types)

The id is a **value-witness**: write a codec and its `T` becomes the screen's static id type (`.uuid` ⇒ `String`). Type safety is that `T` — the codec itself is for **restoration and deep links**, a strict string ↔ `T` round-trip whose `decode` returns `null` to reject malformed input (it validates the *string form*, it doesn't add a finer static type):

`.string .raw .uuid .username .email .integer .number .date .enumValues(...) .record2/.record3(...) .csv(...)` — or any `const` class implementing `Codec<T>`.

## Host & lifecycle

```dart
MaterialApp.router(routerDelegate: Screen.delegate)   // Router integration
MaterialApp(home: Screen.manager())                   // standalone: owns system back + auto restore

final off = Screen.observe((from, to) { ... });       // post-commit listener, no veto
final snap = Screen.snapshot();                        // manual snapshot
Screen.restore(snap);                                  // best-effort; truncates at first illegal edge
```

`NavGraph` takes a required typed `initial:` (e.g. `initial: .profile.settings`), optional `pageOf` (defaults to `MaterialPage`), and optional `observers`. Mount another enum's screen family with `graft(Other.tree())`.

**Scope:** canon owns an in-memory stack and system back — it's an app router. It does not sync the browser URL bar or history; inbound deep links come through `canon_link`, and web address-bar sync is out of scope for now.

## Guarantees

- **Compile-time:** illegal targets, missing/mistyped ids, and back-at-root aren't expressible — the methods don't exist or don't type-check.
- **Build-time validation:** one owner per screen name; every declaration of a name agrees on id type; `inherit` must target a real ancestor with a matching id type; `keep`/`forget` must genuinely flip retention.
- **Runtime:** a placement's verbs are edge-required — they throw on a stale-invalid edge rather than silently teleporting. The engine's raw `go`/`pop` are `@internal`; the typed verbs are the only navigation surface.
- **Drift check:** `assert(Screen.isCodegenFresh)` in a test fails if codegen and the live tree diverge.

The payoff: the spec at the top of this file *is* the complete, auditable nav space. A model can only emit legal navigation, and a human reviews every reachable route at a glance.

## Install

```yaml
dependencies:
  canon: ^0.15.1            # runtime
dev_dependencies:
  canon_generator: ^0.19.0  # codegen — emits screen.nav.dart
  build_runner: any
```

`dart run build_runner build` generates the typed `Screen` facade. For deep links, add **canon_link** — a strict URL ↔ sealed `Link` codec built from the same grammar.
