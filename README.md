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

  static final graph = NavGraph({
    home.keep({ _user() }),
    search.keep({ _user(), comment })
      .query({ _View.text(.string), _View.sort(.enumValues(SortBy.values)) }),  // URL ?text=&sort= — historyless mirror
    messages.keep({ thread({ _user() }).fragment({ _View.at(.uuid) }) }),       // URL #at=<msgId> — a scroll anchor
    profile.keep({
      // editPost's id is always this post's; `dirty` is a shared flag (any editor
      // can mirror it) → a global close-guard can ask "is anything unsaved?"
      post({ editPost.inherit(post).query({ _View.dirty }), comment }),
      settings,
    }),
    user.link({ slot(.username) }),               // /user/<username> — a shareable deep link → user
  }, root: const SplashScreen());              // boot UI, until the resolver commits the first screen
}

// View-state keys (the URL `?query` / `#fragment`) — a QueryKeyBase enum, `key(codec)`.
enum _View with QueryKeyBase { text, sort, at, dirty }
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

**Atomic** — a chain written in one expression commits as a **single** transition: one diff against the live stack, one animation. Entries that still match (same screen **and** id) are **reused, not rebuilt**, so the chain changes only what actually differs. That's why `Screen.at(.home)?.goSettings()` *pops what's above home and reuses the rest* — a minimal jump, never a teardown-and-recreate — and why a `surface()`-then-`go` reads as a single declarative "end up here."

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
Screen.on(.parentOf.home);                  // compile error — home is a trunk, it has no parent
```

## Recursion: stacked vs cycled

A profile links to other profiles, and a post links back to its author. Two distinct recursions, both explicit in the tree:

- `user.stacked` — drill-in: push a **fresh** instance, keep intermediate frames (follower → follower → follower).
- `user.cycled` — exactly `stacked`, plus one rule: it won't stack a second identical copy of a cycle. If a move would repeat a run of frames (same screens **and** ids) back-to-back, canon drops the repeat and returns you to the existing run; any differing id breaks the match, so it just stacks.

Cyclic screens expose `depth` (live occurrence count); `.depth(n)` pins one:

```dart
if (Screen.current case HomeUserNav(:final depth)) { ... }   // how deep in the chain
Screen.on(.user.depth(2))?.popToUser();                 // act on a specific occurrence
```

## Back

`Screen.canPop` is `null` iff you're at a trunk. `Screen.pop()` is sugar for `Screen.canPop?.pop()` — it pops if it can and returns where you landed (or `null` at a trunk), never throws. That destination is a union over every non-leaf placement (anywhere you could land), so narrow it with `.at`:

```dart
final landed = Screen.pop();        // null at a trunk
switch (landed?.at) { /* one case per non-leaf placement — exhaustive */ }
```

`Screen.on(...)`, `Screen.current`, and every move return a **placement** — a typed `…Nav` like `ThreadNav` or `HomeUserNav`. It's a transient cursor: each move returns the **next** placement and you step from that.

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

## Inspect & reach a position — typed, exhaustive

**The bug:** `"is route X active?"` by string/regex compare.

**Foreclosed:** `Screen.current` is the exact foreground placement (never null), a sealed `AnyPlacement` you switch exhaustively. `Screen.on(.user)` is `user`'s placement **if it's the front**, else `null` — and it's already the typed placement, so a placement you forget to handle **won't compile**:

```dart
if (Screen.current case HomeUserNav n) ...      // exact front placement

switch (Screen.on(.user)) {            // no default — add a placement and this won't compile
  case HomeUserNav():            ...
  case SearchUserNav():          ...
  case MessagesThreadUserNav():  ...
  case null:                     ...   // user is not the front
}
```

`Screen.on(.x)` is **front-only**; `Screen.at(.x)` reaches a placement **anywhere on the live stack** — front *or* buried. On it, `surface()` brings it to the front (a no-op if it already is), and `goX()` is a **smart jump** — pop back to it, then navigate, as one atomic diff:

```dart
Screen.at(.user(id))?.surface();       // bring that user up (no-op if already front)
Screen.at(.home)?.goSettings();        // jump back to home, then settings — one diff
```

`Screen.stack` exposes `.current`, `.currentId`, `.screens`, `.reachable`, and `.tab` (the active trunk — the bottom of the stack).

Each reach has two forms. **`Screen.on`/`Screen.at`** read a placement *once* — to inspect or navigate. **`context.on`/`context.at`** are their reactive twins: the same selector, but they return the typed **view** and **rebuild the widget surgically** — only when a key the selector names (or the foreground) actually changes, never on unrelated nav. Two axes: `Screen.` vs `context.` = read-once vs reactive rebuild; `.on` vs `.at` = foreground vs anywhere on the stack. (`Screen.<screen>Of(context)` reads this widget's *own* placement.)

## Read a screen's own id

**The bug:** a mirrored `currentUserId` provider, or id threaded through every constructor — two sources of truth that drift.

**Foreclosed:**

```dart
final userId = context.idOf(.user);   // typed, never null for an id-bearing screen
context.idOf(.home);                  // compile error — home has no id
```

No `InheritedWidget`, no mirror, no route-param threading. (When one widget backs 2+ id-bearing screens, codegen emits a sealed `Screen.<widget>Id(context)` resolver you switch exhaustively — not needed in this tree.)

## View-state: typed URL query/fragment, reactive

`search.query({...})` / `thread.fragment({...})` declare **screen-local view-state** — nullable, typed, mirrored into the URL's `?query` / `#fragment` as a *historyless* replace (it never floods back-history). Write it through the placement; read it surgically in a widget:

```dart
Screen.on(.search)!.query.sort = .recent;          // write — mirrors to ?sort=recent

final text = Query.of<String>(context, _View.text); // read ONE key — rebuilds ONLY when `text` changes
```

`Query.of` / `Fragment.of` are fine-grained: a widget watching a key rebuilds only when *that* key changes — selection rebuilds with no provider/selector boilerplate. `context.on(.x)` reads the typed view through the placement reactively, **subscribing only to the keys (and foreground) the selector references**:

```dart
final search = context.on(.search.query({.sort(.recent)}));  // SearchView? (null off search / when sort ≠ recent)
// rebuilds when `sort` changes value or search (de)foregrounds — never on unrelated nav or other keys;
// no change to a watched value → no rebuild

// global, across screens: a flag read anywhere on the stack — true while ANY
// editor is dirty. Backs a close-guard; rebuilds only when a `dirty` flips.
final unsaved = context.at(.query({.dirty})) != null;
```

`context.on` is the foreground read, `context.at` the same anywhere on the stack; a placement-less `On.query({...})` reads view-state **globally** across screens (the close-guard above). `Screen.ownerOf(context)` / `isForegroundOf(context)` read this widget's own placement, reactively.

## State retention

`keep` / `forget` decide whether a scope's stack **survives leaving it for another trunk** (a kick-start to a different family) and coming back — build-time checked to actually flip inherited state, so a no-op annotation won't compile:

```dart
home.keep({ _user() })   // jump to another trunk and back → home's stack is intact
child.forget()           // this subtree is dropped, rebuilt fresh on return
```

Retention applies only to that trunk switch — a `popTo`/`go` to an ancestor *within* the scope pops the screens above as normal; they're gone.

## Codecs (id types)

The id is a **value-witness**: write a codec and its `T` becomes the screen's static id type (`.uuid` ⇒ `String`). Type safety is that `T` — the codec itself is for **restoration and deep links**, a strict string ↔ `T` round-trip whose `decode` returns `null` to reject malformed input (it validates the *string form*, it doesn't add a finer static type):

`.string .raw .uuid .username .email .integer .number .date .enumValues(...) .record2/.record3(...) .csv(...)` — or any `const` class implementing `Codec<T>`.

## Build a shareable link

The inverse of the resolver: every screen is also a deep link, and the typed builder turns a route into a URL with `.toUri()` — no string-building, every id checked by its codec.

```dart
Link.home.user('u1').toUri()                 // /home/user/u1 — address it the way you'd navigate
Link.editPost('p1').toUri()                  // /profile/post/p1/edit-post — jump straight to an
                                             //   unambiguous screen; the one id back-fills its path
Link.search.query({.text('shoes')}).toUri()  // /search?text=shoes — view-state rides the SAME
                                             //   dot-shorthand set as Screen.on, minus .not
```

`WidgetLink.<route>` is the nav tree (every renderable screen); a `.link` branch adds **resolve-only** leaves on `WidgetlessLink.<route>` (`/<username>` → `username`, no screen yet); `Link.<route>` is both.

## Host & lifecycle

```dart
MaterialApp.router(routerDelegate: Screen.delegate)   // Router integration
MaterialApp(home: Screen.manager())                   // standalone: owns system back + auto restore

final off = Screen.observe((from, to) { ... });       // post-commit listener, no veto
final snap = Screen.snapshot();                        // manual snapshot
Screen.restore(snap);                                  // best-effort; truncates at first illegal edge
```

`NavGraph` takes a required `root:` **boot widget** (a splash, shown until the first real screen commits), optional `pageOf` (defaults to `MaterialPage`), and optional `observers`. Mount another enum's screen family with `graft(Other.tree())`.

**Cold start & deep links.** `root:` is a boot widget shown until the first screen commits. Two listeners drive the rest:

- a **link resolver** turns every incoming link — the launch URL *and* runtime deep links — into navigation. The grammar's `.link` branches parse each to a typed `Link`, which you `switch` to a `goX`; the first commit out of boot **auto-replaces** the splash, leaving no history:

  ```dart
  switch (link) {                          // resolver — handles the initial link AND later ones alike
    case UserLink(:final username): Screen.goUser(username);
    case null:                      Screen.goHome();       // no/unknown link → default
  }
  ```

- the **navigations stream** (`Screen.navigations` / `Screen.observe`) fires after each commit with the **source and destination stacks** — diff them for transitions, analytics, or restoration.

The boot widget itself reads `Screen.rootUrl` (the launch link, parsed) only to **tailor the loading UI** — e.g. show a profile skeleton when the app opened on a user link — while the resolver does the actual navigating.

**Scope:** canon owns an in-memory stack and system back — it's an app router that also mirrors the active path and view-state into the URL (`?query`/`#fragment`, historyless), builds shareable links with `.toUri()`, and parses inbound ones from the grammar's `.link` branches. Full browser back/forward history sync is in progress. `canon_link` remains the standalone, **Flutter-free** URL ↔ sealed-`Link` codec for non-Flutter consumers.

## Guarantees

- **Compile-time:** illegal targets, missing/mistyped ids, and back-at-trunk aren't expressible — the methods don't exist or don't type-check.
- **Build-time validation:** one owner per screen name; every declaration of a name agrees on id type; `inherit` must target a real ancestor with a matching id type; `keep`/`forget` must genuinely flip retention; a name is a screen *or* a `.link` branch at a given position, never both; redundant forms are rejected — a bare leaf (`X`, not `X()`), and no empty `slots({})` (a screen is already linkable by its id).
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

`dart run build_runner build` generates the typed `Screen` facade — typed nav, URL mirror, `.link` ingress + `.toUri()` link builders, and view-state, all from the one grammar.
