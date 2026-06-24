# Merged canon + canon_link tree — design spec

> Status: **DESIGNED, not built.** The **rules** are locked and the **syntax** is settled; all design
> decisions are resolved. What remains (bottom) is implementation only.

---

## Locked rules

**Identity**
1. **One codec per screen id** — the id *is* identity (equality, `IdentityMap`, `.cycled`, dedup).
   No union codecs on a screen id; multiple URL reprs live in the link/resolver layer.

**`.initial` boot widget + generated `Initial`**
2. `initial:` takes a **widget** (the loading UI, `InitialScreen()`) — NOT a screen value, NOT a reserved
   name (a consumer may still name a screen `initial`). The generator **unconditionally** emits a boot
   placement **`Initial`** (`final class Initial extends AnyNav` — **no `Nav` suffix** so it can't collide
   with a `<screen>Nav`; **no `goInitial`** so it's unreachable by navigation). `Screen.at` returns it
   while booting → **`Screen.at case Initial()`**. Engine shows the widget on **blob-null cold-boot**
   (restore bypasses it) and **auto-replaces the first commit** out of boot (current is `Initial`).
   *(Replaces canon's old `InitialScreen`-chain mechanism — remove it, which frees the `InitialScreen`
   name for the consumer's boot widget.)* `Initial` can soft-clash with a consumer's own `Initial` state
   class — import-prefix resolvable, and rarely hit since the resolver never queries boot.
3. Cold URL read via **`Screen.initialUrl`** — typed **`Link?`** (already parsed; null = no link /
   not representable). No member on `Initial`, no `onInitial` — query via `Screen.at`, link via `initialUrl`.
4. `wasAuthenticated` lives in the resolver, not `main()`.

**Nav vs links**
5. canon tree = **all valid stack positions**; every with-widget placement **auto-deep-links**
   via its nav-mirror URL (internal ids). Declared for free.
6. A declared **link = a no-widget branch**. Additive. No-widget path-words come in two forms:
   - **terminal value** (`me`) → a **literal codec** inside the slot: `slot`/`slots({.literal('me'), …})`.
   - **branch** (`invite`, `chat` — has children) → a **null-widget node** (not a `SizedBox` sentinel).
7. **`.call`** (`X({...})`) = landable screen + nested grammar. The screen enum gains a **`.links`**
   method alongside `.call`. `.links` is the **one-time boundary** into link-world.
8. **`.links` is one-way, enforced by types.** Inside link-world the children are canon_link
   `LinkTreeNode`s (segs/slots) which expose `.call` but **not** `.links` — so nesting `.links`
   is a compile error, not a convention. A nav set accepts screens; a link set accepts only segs/slots.
9. A **`.links` branch may be a child of ANY `.call` placement**, not only a graph root.
10. **`null` in a children set = this node is itself a terminal endpoint.**
    `slot(...)({null, editAd})` → `/ad/<adId>` valid (null) *and* `/ad/<adId>/edit-ad` valid (editAd).
11. **Direct vs resolved**: a parsed value that **is** the id → **direct** (renderable now, no lookup);
    a value needing a lookup/action → **resolved** (no widget until resolved).
12. **Deep-without-intermediate** allowed only in link-world; never in nav (the stack invariant
    guarantees landable ancestors).
13. **No `me` static** — `me` is a literal codec branch; its mapping to self (`profile`) is resolver logic.

**Generated `Link` surface**
14. `Link` is **sealed into two families: `WidgetLink` vs `WidgetlessLink`**:
    - **widget** = the URL fully determines a renderable screen/stack with no lookup → seed directly.
    - **widgetless** = no screen until resolved (lookup / action).
    A single union slot can produce cases in **both** families (e.g. `/user/<uuid>` → widget,
    `/user/<username>` & `/user/me` → widgetless).

**Resolver**
15. **One resolver listener** (outside the widget tree, deep_link-shaped):
    `resolve(link) → target → reconcile-stack-to-target`.
    Cold = reconcile-from-empty (seed); warm mobile = reconcile-from-live (stack-aware).
    Same reconcile as web back/forward. **Web links are 100% cold-start**; warm `uriLinkStream` is mobile-only.

**URL roles & blob**
16. Two roles: in-session **derived nav-mirror** (lossy, internal ids) + cold-start **declared-link ingress**.
17. **Blob = truth** (`toState` snapshot, survives reload) for back/forward/refresh;
    URL = derived lossy mirror, self-sufficient only on cold-load (truncate-to-valid-prefix).

**Query/fragment = view-state (DESIGNED, demand-gated, do NOT build yet)**
18. View-state: **screen-only, local, historyless (replaceState), persistent**; non-identity.
19. Lives in canon's screen state (`toState`) with a **setter**; URL is a derived mirror (**no listeners**);
    causes render only at cold-start/restore.
20. `q.of(context)` for widgets + **imperative getter** for headless; Riverpod consumes it as **family args**.
21. **Registry-value → PATH** (key → re-fetch); **state-value → QUERY** (value → restore).
22. Uniform query/fragment syntax; **`.call`/`.links` position disambiguates** view-state vs resolver-param.
23. **Round-trip**: one codec both directions; omit-on-default ⟺ absent-is-default.
    Query/fragment keys come from a **query-key enum** (`QueryKeyBase`): `key(codec)` = value, bare key = flag.

**Naming**
24. Enum name = value. **Path segments → kebab-only** (`adChat` → `/ad-chat`), **no per-node override**.
    Need a different/stable public URL? **Declare a link branch** with that name — link branches are
    the stable shareable contract; nav-mirror segments (kebab of screen name) change on rename and are
    best-effort "wherever you are."
    **Query/fragment keys → camelCase** (`sortOrder` → `?sortOrder`). Codec field-name override is a
    **symbol on the codec** (`.uuid(#adId)`) and is itself camelCase→kebab.

**Codecs (canon_codec additions)**
25. For static-value matching in slots, canon_codec gains exactly two: **`Codec.literal('me')`**
    (exact verbatim match; the string doubles as the branch name, override via `.literal('me')(#name)`)
    and **`Codec.regex(pattern)`**. Consumer chooses; **docs recommend `literal`**. *(IMPLEMENTED — string
    not symbol: a literal must stringify at runtime, and `Symbol→String` needs mirrors, absent in AOT.)*

**Cross-platform**
26. Shared URL + app installed → **opens the app, same resolver/cold-load as web**; broad app-route
    domain claim, web-only pages excluded; no per-link registration.

**Packaging**
27. canon **grows** the link capability; **canon_link stays a separate standalone package**;
    canon_codec shared; dedup later.

**Per-platform trees (PARKED)**
28. Runtime `if/switch` tree parts erode compile-safety; compile-time conditional imports preserve it. Deferred.

---

## Example: enum + tree

```dart
@screens
enum _Screens with ScreenNode<_Screens> {
  // tabs / roots
  home(HomeScreen()),
  feed(FeedScreen()),
  myAds(MyAdsScreen()),
  chats(ChatsScreen()),

  // auth
  email(EmailScreen()),
  otp(OtpScreen()),

  // self
  profile(ProfileScreen()),
  browseSettings(BrowseSettingsScreen()),

  // others / entities
  user(UserScreen(), .string),
  ad(AdScreen(), .string),
  editAd(EditAdScreen(), .string),
  draft(DraftScreen()),
  camera(CameraScreen()),

  // chats / detail
  adChat(ChatScreen(), _ChatId()),
  loopChat(ChatScreen(), .string),
  adPreview(AdPreviewScreen(), .string),

  // no-widget path-word BRANCH (open: which enum hosts null-widget nodes?)
  invite(null);

  const _Screens(this.widget, [this.id]);
  @override
  final Widget? widget;
  @override
  final Codec? id;

  static _Screens _user() => user({
        user.stacked,
        loopChat({user.cycled}),
        adChat({user.cycled, adPreview}),
      });

  static final graph = NavGraph<_Screens>(
    {
      // ── NAV (.call placements) — every node auto-deep-links (nav-mirror, internal ids)
      home({browseSettings, _user()}),
      feed({_user()}),
      myAds({
        draft({camera}),
        ad({editAd.inherit(ad), adChat({adPreview, _user()})}),
      }),
      chats({
        adPreview,
        _user(),
        loopChat({_user()}),
        adChat({adPreview, _user()}),
        // link-only branch nested inside a nav placement (rule 9):
        invite.links({slot(.string(#code))}),   // /chats/invite/<code>  → resolver redeems
      }),
      email({otp}),
      profile,

      // ── LINKS (.links branches) — pure URL grammar, resolver-mapped, link-only below.
      //    inside .links, children are call-form segs/slots (rule 8); `null` = terminal (rule 10).

      // precedence me → uuid → username (slot codec order). me/username = widgetless, uuid = widget.
      user.links({slots({.literal('me'), .uuid(#userId), .username})}),
      ad.links({slot(.uuid(#adId))({null, editAd})}),   // /ad/<adId>  AND  /ad/<adId>/edit-ad

      // demand-gated view-state (do NOT build) — query/fragment + naming:
      //   keys come from a query-key enum (QueryKeyBase); `key(codec)` = value, bare key = flag
      // feed({_user()}).query({category(.string), radius(.int)}),   // /feed?category=&radius=
      // adChat({...}).fragment({message(.string)}),                 // /ad-chat/<id>#message=
    },
    initial: InitialScreen(),   // a WIDGET (rule 2); name freed by dropping the old InitialScreen chain
  );
}
```

---

## Example: initial widget

```dart
// Boot-only loading UI. The resolver (outside the tree) drives navigation.
// Engine shows this ONLY on blob-null cold-boot; restore bypasses it.
class InitialScreen extends StatelessWidget {
  const InitialScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // may read Screen.initialUrl (a Link?) to theme the loading — not required to.
    return const Scaffold(body: Center(child: Loading()));
  }
}
```

---

## Example: resolver

```dart
class LinkResolver extends Notifier<void> {
  @override
  void build() {
    final boot = Screen.initialUrl;            // Link? — parsed at boot
    if (boot != null) _resolve(boot); else _default();
    // warm: links while running — MOBILE ONLY (web warm = reload = cold)
    final sub = ref.appLinks.uriLinkStream.listen((uri) {
      final link = Links.parse('$uri');
      if (link != null) _resolve(link);
    });
    ref.onDispose(sub.cancel);
  }

  void _default() => ref.read(authProvider).isAuthed ? Screen.goHome() : Screen.replace.goEmail();

  // UNAWARE of cold-vs-warm: the engine auto-replaces the first commit out of boot (current is
  // `Initial`) and pushes otherwise, so the resolver just writes plain Screen.goX(). `Screen.replace`
  // is only for a live-stack redirect (auth bounce) that must never be a back-target.
  Future<void> _resolve(Link link) async {
    if (!ref.read(authProvider).isAuthed) { Screen.replace.goEmail(); return; }
    switch (link) {
      // ── widget links — renderable now, seed directly (no lookup) ──
      case UserByIdLink(:final userId): Screen.goHome().goUser(userId);
      case AdLink(:final adId):         Screen.goHome().goAd(adId);
      case EditAdLink(:final adId):     Screen.goHome().goAd(adId).goEditAd(adId);
      // ── widgetless links — resolve first ──
      case UserMeLink():                Screen.goHome().goProfile();
      case UserByNameLink(:final username):
        final id = await ref.ws.resolveUsername(username);   // username → userId
        Screen.goHome().goUser(id);
      case InviteLink(:final code):
        await ref.ws.redeemInvite(code);
        Screen.goChats();
    }
  }
}

final linkResolverProvider = NotifierProvider(LinkResolver.new);
```

```dart
// generated by canon_link — sealed into widget vs widgetless families (rule 14):
sealed class Link { const Link(); }   // const: subclasses have const ctors
sealed class WidgetLink     extends Link {}   // renderable now → seed directly
sealed class WidgetlessLink extends Link {}   // needs resolution → resolver runs first

// per-entity grouping — a sealed marker the concrete cases IMPLEMENT (while EXTENDing a
// family). Cross-cuts widget/widgetless, so `case UserLink()` catches any user link, OR
// you switch the concrete cases exhaustively.
sealed class UserLink implements Link {}

final class UserByIdLink   extends WidgetLink     implements UserLink { const UserByIdLink(this.userId);     final String userId; }   // /user/<userId>
final class UserByNameLink extends WidgetlessLink implements UserLink { const UserByNameLink(this.username); final String username; } // /user/<username>
final class UserMeLink     extends WidgetlessLink implements UserLink { const UserMeLink(); }                                         // /user/me

final class AdLink     extends WidgetLink     { const AdLink(this.adId);     final String adId; }   // /ad/<adId>
final class EditAdLink extends WidgetLink     { const EditAdLink(this.adId); final String adId; }   // /ad/<adId>/edit-ad
final class InviteLink extends WidgetlessLink { const InviteLink(this.code); final String code; }   // /chats/invite/<code>

abstract class Links {
  static Link? parse(String url);   // strict decode; null = not representable
  static String of(Link link);      // encode (for share / outbound)
}
```

---

## Resolved

- **Per-form `Link` shape** → sibling cases extending widget/widgetless, IMPLEMENTing a per-entity
  sealed marker (`UserLink`). One declaration may split across both families (intended).
- **Null-widget path-words** → null-widget rows in `@screens` (`widget` is `Widget?`); `invite(null)`.
- **Union-branch naming** → auto-name from the codec by default; explicit `#name` to override
  (`.username` ⇒ `username`, `.username(#theUsername)` to override).
- **Type names** → `WidgetLink` / `WidgetlessLink`.
- **Cold vs warm** → one listener, no flag; the engine derives it from the current placement
  (`Screen.at is Initial`). At-boot → auto-replace; live → push. Resolver writes plain `Screen.goX()`.

## Resolved — `replace`-vs-`push`

Warm reconcile is NOT a canon policy — it's plain imperative consumer logic (`switch` + `Screen.on`/`at`),
same as cold and as allinloop's `deep_link` today. The only real gap was a **`replace` capability on
navigation** (replace the current entry vs push a new one; web → `replaceState` vs `pushState`,
mobile → no back-target vs one). The commit carries an **`enum { push, replace }`**, not a bool.

**Auto-derived (engine-internal):**
- **current is `Initial`** (first commit out of boot) → **replace** — overrides the flag; the boot entry
  must never be a back-target.
- view-state setter (query/fragment, rule 18) → **replace** (historyless)
- plain `Screen.goX` / `Screen.on` → **push** (the default `push` flag)

**Explicit (live-stack redirect — auth bounce, legacy forward): `Screen.replace`, a STATIC-ONLY getter.**
```dart
Screen.goHome();                            // push
Screen.replace.goEmail();                   // replace the current entry
Screen.replace.on(.user)?.goLoopChat(id);   // scoped redirect — replace decided AT THE START
```
- `Screen.replace` lives **only on the static `Screen` facade**, NOT on the `Nav` instance type. It
  returns a normal `Nav` with the commit flag set to `replace`; the flag rides the chain to the one commit.
- Because `Nav` instances have no `.replace`, the pathological chains are **un-writable, not just
  discouraged**: `Screen.replace.replace` ✗, `Screen.on(.X)?.replace` ✗, `Screen.goHome().replace` ✗.
- You decide replace **at the start** (`Screen.replace.on(.X)?.goY()`), never after scoping — exactly how
  a redirect reads ("this whole action is a replace"). No capability lost; no `ReplaceModeNav` copy needed.
- The chain commits as **ONE** history entry, so the whole resulting stack replaces (no phantom
  intermediate) — confirm chain = one commit.

## Still open

Nothing design-level. Remaining work is **implementation**: the `Initial` boot placement + engine
auto-replace (`current is Initial`), the `Screen.replace` static getter + `enum { push, replace }` commit
flag, the literal/regex codecs, `Screen.initialUrl` + the merged generator surface, removing the old
`InitialScreen`-chain mechanism, and (demand-gated) the query/fragment view-state axis.
```
