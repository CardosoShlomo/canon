import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show MaterialPage;
import 'package:flutter/widgets.dart';

import 'package:canon_codec/canon_codec.dart';

import 'browser_history.dart';

import 'link_dsl.dart';
import 'link_matcher.dart';
import 'link_spec.dart';
import 'screen_node.dart';

/// Default page when the consumer gives no `pageOf`: a platform Material page.
Page<void> _defaultPageOf(Widget widget, PageCtx ctx, LocalKey key) =>
    MaterialPage<void>(key: key, child: widget);

/// The shape of a committed navigation, derived from the active scope's stack
/// delta: [forward] grew the stack, [backward] shrank it, [roundTrip] did both
/// (a `popTo(...).go(...)` chain), [jump] switched scope/trunk (a kick-start).
enum NavDirection { forward, backward, roundTrip, jump }

/// How a committed navigation maps to history: [push] adds a new entry,
/// [replace] overwrites the current one (no back-target). Default is [push];
/// the generated `Screen.replace` flips a batch to [replace], and the engine
/// forces [replace] for the first commit out of the boot state. The web Router
/// delegate reads it (`pushState`/`replaceState`); the bare stack engine, which
/// has no history, ignores it.
enum CommitMode { push, replace }

/// The kind of synthetic base entry sitting at history index 0 (null = none):
/// - [kept]: a real position we persist (e.g. a pasted deep link) — never killed,
///   renders its own content, back returns to it then exits.
/// - [fallthrough]: an armed sentinel — when it comes to the front (back lands on
///   it) it runs `go(-1)` to leave the app and flips itself to [sentinel].
/// - [sentinel]: a spent placeholder — doesn't bounce; the next deepening
///   navigation kills it by re-basing the stack at index 0.
enum FloorKind { kept, fallthrough, sentinel }

/// An immutable snapshot of one committed navigation, delivered to
/// [NavGraph.navigations]. Safe to hold past the commit: it captures the
/// transition rather than reading live state, so async (stream) delivery never
/// sees a stale position. [from] and [to] are the full active-scope stacks
/// (bottom-to-top, each entry a `(screen, id)`); the generated layer retypes
/// them into the public `ScreenEntry` stack.
final class Navigation {
  Navigation({required this.from, required this.to, this.mode = .push});

  /// Full active-scope stack BEFORE the navigation, bottom-to-top.
  final List<(Enum, Object?)> from;

  /// Full active-scope stack AFTER the navigation, bottom-to-top.
  final List<(Enum, Object?)> to;

  /// Whether this commit pushes a new history entry or replaces the current one.
  final CommitMode mode;

  /// The top entry left / landed on.
  (Enum, Object?) get source => from.last;
  (Enum, Object?) get destination => to.last;

  // Everything below is DERIVED from [from]/[to] — no stored state. Entries
  // compare by value `(screen, id)`, so a cycle's repeated frame is handled.
  bool get _sameTrunk => from.first.$1 == to.first.$1;

  late final int _common = () {
    if (!_sameTrunk) return 0;
    var c = 0;
    while (c < from.length && c < to.length && from[c] == to[c]) {
      c++;
    }
    return c;
  }();

  NavDirection get direction {
    if (!_sameTrunk) return NavDirection.jump;
    final popped = _common < from.length;
    final pushed = _common < to.length;
    return popped
        ? (pushed ? NavDirection.roundTrip : NavDirection.backward)
        : NavDirection.forward;
  }

  /// The deepest screen both stacks share, above which they diverged; null on a
  /// scope [jump] (no common stack).
  Enum? get pivot => _sameTrunk && _common > 0 ? from[_common - 1].$1 : null;

  /// Screens left behind (popped above the pivot), bottom-to-top.
  List<Enum> get popped =>
      _sameTrunk ? [for (var i = _common; i < from.length; i++) from[i].$1] : const [];

  /// Screens entered (pushed above the pivot), bottom-to-top.
  List<Enum> get pushed =>
      _sameTrunk ? [for (var i = _common; i < to.length; i++) to[i].$1] : const [];

  bool get isForward => direction == NavDirection.forward;
  bool get isBackward => direction == NavDirection.backward;
  bool get isRoundTrip => direction == NavDirection.roundTrip;
  bool get isJump => direction == NavDirection.jump;

  @override
  String toString() =>
      'Navigation(${from.last.$1.name} → ${to.last.$1.name}, ${direction.name})';
}

/// Default when the consumer gives no `observers`.
List<NavigatorObserver> _noObservers() => const [];

/// The spec-enum contract: a screen family carrying the grammar AND a `Widget`.
/// Binds the engine's abstract widget slot to Flutter's `Widget`, so consumers
/// write the clean form and `Widget get widget` is required:
///   `enum _Screens with ScreenNode<_Screens> { ... final Widget widget; }`
typedef ScreenNode<S extends ScreenNodeBase<S, Widget>> = ScreenNodeBase<S, Widget>;

/// A sub-enum's contract: like [ScreenNode] but the widget is OPTIONAL, so a row
/// can be a bare ref to an owner screen of the same name (the owner carries the
/// widget). Sub-enums mix this in; the trunk keeps [ScreenNode] (widget required),
/// so the trunk can never be a ref.
typedef SubScreenNode<S extends ScreenNodeBase<S, Widget?>>
    = ScreenNodeBase<S, Widget?>;

/// The page's grammar identity and transition policy inputs.
final class PageCtx {
  const PageCtx(this.screen, {this.animate = true, this.from});

  /// The screen this page renders. Ids are read inside the screen via the
  /// generated `context.idOf(...)`, not here — pageOf never sees a raw id.
  final Enum screen;

  /// False for pages that materialized mid-chain — suppresses their transition.
  final bool animate;

  /// Top screen when this page was pushed.
  final Enum? from;
}

/// Scopes a page's screen and id to its subtree, and gates its content: while
/// the tab is active everything renders; once parked, only screens that are
/// kept-when-parked (`keep`/`forget`) keep their real content — the rest
/// collapse to a `SizedBox` (freed, rebuilt fresh on return). With no liveness
/// in scope it always renders, so consumers not using it just keep all alive.
/// Internal: canon wraps each page in this (see `_buildPage`). Consumers never
/// construct it — they read their screen via the generated `context.idOf`/
/// `context.screen`, which route through the statics here.
@internal
final class ScreenScope extends StatelessWidget {
  const ScreenScope({super.key, required this.entry, required this.child});

  final StackEntry entry;
  final Widget child;

  /// The screen this context is under. Carries no id — read ids only via the
  /// typed [idOf], so a raw `Object?` id is never exposed to screen code.
  static Enum of(BuildContext context) => _entryOf(context).screen;

  static StackEntry _entryOf(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ScreenEntry>();
    assert(scope != null, 'no ScreenScope above this context');
    return scope!.entry;
  }

  /// The typed id of screen [spec] this context is under. The single sanctioned
  /// id read; an id-bearing screen always has its id, so [T] is non-null.
  static T idOf<T>(BuildContext context, Enum spec) {
    final entry = _entryOf(context);
    assert(identical(entry.screen, spec),
        'idOf(${spec.name}) read under ${entry.screen.name}');
    return entry.id as T;
  }

  @override
  Widget build(BuildContext context) {
    final live = _ScopeLiveness.of(context);
    final show = live == null || live.active || live.kept(entry.screen);
    return _ScreenEntry(
      entry: entry,
      child: show ? child : const SizedBox.shrink(),
    );
  }
}

/// Carries the page's grammar entry to descendants (the `of` lookup).
final class _ScreenEntry extends InheritedWidget {
  const _ScreenEntry({required this.entry, required super.child});

  final StackEntry entry;

  @override
  bool updateShouldNotify(_ScreenEntry oldWidget) => false;
}

/// Per-scope liveness the delegate provides: whether this tab is active, and
/// which of its screens stay live while parked. A flip of [active] re-gates the
/// scope's `ScreenScope`s.
final class _ScopeLiveness extends InheritedWidget {
  const _ScopeLiveness(
      {required this.active, required this.kept, required super.child});

  final bool active;
  final bool Function(Enum) kept;

  static _ScopeLiveness? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ScopeLiveness>();

  @override
  bool updateShouldNotify(_ScopeLiveness oldWidget) => active != oldWidget.active;
}

/// Reactive view-state. Widgets depend on a single key aspect (`q:screen.key` /
/// `f:screen.key`) and rebuild ONLY when that key is added, removed, or changed —
/// not on unrelated view-state or navigation. Provided above the Navigators.
final class _ViewModel extends InheritedModel<String> {
  const _ViewModel({required this.snapshot, required super.child});

  final Map<String, Object?> snapshot;

  static Object? read(BuildContext context, String aspect) =>
      InheritedModel.inheritFrom<_ViewModel>(context, aspect: aspect)
          ?.snapshot[aspect];

  // Subscribe to a (screen, key) across both URL parts (a key lives in exactly
  // one; the other aspect never fires) and return its live value.
  static Object? readKey(BuildContext context, Enum screen, String key) {
    final q = read(context, 'q:${screen.name}.$key');
    final f = read(context, 'f:${screen.name}.$key');
    return q ?? f;
  }

  @override
  bool updateShouldNotify(_ViewModel old) => !mapEquals(snapshot, old.snapshot);

  @override
  bool updateShouldNotifyDependent(_ViewModel old, Set<String> aspects) =>
      aspects.any((a) => snapshot[a] != old.snapshot[a]);
}

/// Reactive, screen-local QUERY view-state. `Query.of<String>(context,
/// FeedKeys.category)` returns the value for the screen this context is under AND
/// subscribes the widget to that one key — it rebuilds only when the key is added,
/// removed, or changed. The key comes from a [QueryKeyBase] enum.
abstract final class Query {
  static T? of<T>(BuildContext context, QueryKeyBase key) =>
      _ViewModel.read(context, 'q:${ScreenScope.of(context).name}.${key.name}')
          as T?;
}

/// Like [Query], but for the URL FRAGMENT view-state axis.
abstract final class Fragment {
  static T? of<T>(BuildContext context, QueryKeyBase key) =>
      _ViewModel.read(context, 'f:${ScreenScope.of(context).name}.${key.name}')
          as T?;
}

/// Reactive placement membership. Widgets depend on a single screen aspect and
/// rebuild only when THAT screen enters or leaves the active placement chain
/// (becomes on/at) — not on unrelated navigation.
/// One view-state condition term in a selector (`.category('books')`, `.not.byFav`).
/// The generated per-screen `…Cond` types implement this; `Screen.on`/`context.on`
/// gate on `test(liveValue)`, and [key] is the aspect a reactive read subscribes to.
abstract interface class ViewCond {
  String get key;
  bool test(Object? value);
}

/// Aspect wrapper so `isCurrent` (top==screen) and `isOn` (chain∋screen) can both
/// key on a screen without colliding in [_PlacementModel.updateShouldNotifyDependent].
class _CurrentAspect {
  const _CurrentAspect(this.screen);
  final Enum screen;
  @override
  bool operator ==(Object o) => o is _CurrentAspect && o.screen == screen;
  @override
  int get hashCode => screen.hashCode;
}

final class _PlacementModel extends InheritedModel<Object> {
  const _PlacementModel(
      {required this.chain, required this.top, required super.child});

  final Set<Enum> chain;
  final Enum top;

  static bool isOn(BuildContext context, Enum screen) =>
      InheritedModel.inheritFrom<_PlacementModel>(context, aspect: screen)
          ?.chain
          .contains(screen) ??
      false;

  static bool isCurrent(BuildContext context, Enum screen) =>
      InheritedModel.inheritFrom<_PlacementModel>(context,
              aspect: _CurrentAspect(screen))
          ?.top ==
      screen;

  @override
  bool updateShouldNotify(_PlacementModel old) =>
      top != old.top || !setEquals(chain, old.chain);

  @override
  bool updateShouldNotifyDependent(_PlacementModel old, Set<Object> aspects) {
    for (final a in aspects) {
      if (a is _CurrentAspect) {
        if ((top == a.screen) != (old.top == a.screen)) return true;
      } else if (a is Enum) {
        if (chain.contains(a) != old.chain.contains(a)) return true;
      }
    }
    return false;
  }
}

/// Reactive placement queries. `Placement.isOn(context, V.feed)` → is that screen
/// anywhere on the active chain; `Placement.isCurrent(context, V.feed)` → is it the
/// foreground top. Each rebuilds the widget only when its own status flips. The
/// generated `Screen.of(context, …)` / `Screen.isCurrentOf` forward here.
abstract final class Placement {
  static bool isOn(BuildContext context, Enum screen) =>
      _PlacementModel.isOn(context, screen);
  static bool isCurrent(BuildContext context, Enum screen) =>
      _PlacementModel.isCurrent(context, screen);

  /// The current foreground screen, BROADLY reactive — the widget rebuilds on any
  /// placement change. Backs the generated `Screen.of(context)` switch-to-render.
  static Enum? current(BuildContext context) =>
      InheritedModel.inheritFrom<_PlacementModel>(context)?.top;
}

/// Reactive evaluation of a selector's view-state conditions — subscribes the
/// widget to exactly the keys referenced (so it rebuilds when they change) and
/// returns whether they all hold. Backs the generated `context.on`/`context.current`.
abstract final class ViewMatch {
  static bool conds(BuildContext context, Enum screen, List<ViewCond> conds) {
    for (final c in conds) {
      if (!c.test(_ViewModel.readKey(context, screen, c.key))) return false;
    }
    return true;
  }
}

/// Chain handle: hops queued in one synchronous expression commit together on
/// a microtask — one diff, one animation.
@internal
final class Nav {
  Nav._(this._graph);

  final NavGraph _graph;

  Nav go<T>(Enum screen, [T? id]) => _graph.go(screen, id);

  Nav pop([Enum? until]) => _graph.pop(until);
}

class _Slot {
  _Slot(this.entry, this.page);

  final StackEntry entry;
  final Page<void> page;
}

/// One live stack: a trunk screen's pages plus its Navigator identity.
class _Scope {
  final List<_Slot> slots = [];
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  final HeroController hero = HeroController();
}

/// The batch's working state: per-scope stacks plus the active scope.
class _Sim {
  _Sim(this.stacks, this.active);

  final Map<Enum, List<StackEntry>> stacks;
  Enum active;

  /// Set once per batch by [NavGraph.markReplace]; rides to [Navigation.mode].
  CommitMode mode = .push;

  List<StackEntry> get stack => stacks[active]!;
}

/// A direct stack seed (trunk..target chain of (screen, id)) for the `seedChain:`
/// constructor arg — used by engine/restore code and tests to start at a specific
/// stack. Consumers instead pass `root:` (the boot widget) and let the resolver
/// drive the first navigation; see [BootScreen].
abstract interface class RootScreenBase {
  List<(Enum, Object?)> get chain;
}

/// The synthetic boot placement. When a graph is built with a [bootWidget], the
/// stack is seeded as `[(BootScreen.root, null)]` — so the always-non-empty
/// invariant holds — and `current`/`Screen.at` report it until the first commit,
/// which the engine auto-replaces (the boot entry leaves no history). Never part
/// of a consumer tree; the generated `Screen.at` maps it to `Initial`.
enum BootScreen { root }

// camelCase screen name ⇄ kebab URL segment (`editAccount` ⇄ `edit-account`).
String _urlKebab(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');
String _urlUnkebab(String s) {
  final parts = s.split('-');
  return parts.first +
      parts
          .skip(1)
          .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1))
          .join();
}

final class NavGraph {
  NavGraph(
    Set<TreeNode> trunkScreens, {
    this.pageOf = _defaultPageOf,
    Object? root,
    RootScreenBase? seedChain,
    this._observers = _noObservers,
  })  : assert((root == null) != (seedChain == null),
            'pass exactly one of `root:` (the boot widget) or `seedChain:`'),
        spec = NavSpec(trunkScreens) {
    _linkRoot = _linkRootOf(trunkScreens, spec);
    _collectViewSchema();
    delegate = NavDelegate._(this);
    _bootWidget = root;
    final chain = root != null
        ? const <(Enum, Object?)>[(BootScreen.root, null)]
        : seedChain!.chain;
    _activeTrunk = chain.first.$1;
    final scope = _Scope();
    var node = root != null ? _bootNode : spec.canonical[_activeTrunk]!;
    Enum? from;
    for (var i = 0; i < chain.length; i++) {
      final (screen, id) = chain[i];
      if (i > 0) {
        node = spec.edge(node, screen) ??
            (throw StateError('invalid root chain at "${screen.name}"'));
      }
      final entry = StackEntry(node, id);
      scope.slots.add(_Slot(entry, _buildPage(entry, animate: false, from: from)));
      from = screen;
    }
    _scopes[_activeTrunk] = scope;
    _visited.add(_activeTrunk);
    _visited.sort((a, b) => a.index.compareTo(b.index));
    _initWebHistory();
  }

  /// canon owns the browser history directly on web (raw `pushState` for output,
  /// its own `popstate` for input) — the engine's coalescing history layer is
  /// bypassed. Reads the launch URL and registers the back/forward listener.
  bool _ownsHistory = false;
  void _initWebHistory() {
    if (!kIsWeb || !isBrowser) return;
    _ownsHistory = true;
    // canon speaks the History API directly. Keep the engine in multi-entry so it
    // never eats browser-back (single-entry intercepts it), then canon owns
    // push/replace/go(-N) and reads back/forward via popstate.
    WidgetsFlutterBinding.ensureInitialized();
    enableMultiEntryHistory();
    // A Navigator init during the first frame can re-assert single-entry; re-pin
    // multi-entry after the frame so it sticks.
    WidgetsBinding.instance.addPostFrameCallback((_) => enableMultiEntryHistory());
    onPopState(_onPopState);
    bootUrl = currentPath();
    // Default the cold base by the launch URL: a bare `/` is a plain app-open
    // (throwaway, back exits); a specific path (a pasted/clicked deep link) is a
    // returnable position. Consumer overrides via Screen.root.anchor()/passthrough().
    _rootKept = bootUrl != null && bootUrl != '/' && bootUrl!.isNotEmpty;
    // Refresh PRESERVES history.state. Blob present → refresh-induced cold-start:
    // restore directly, no resolver. Blob absent → genuine external cold-start
    // (pasted/typed URL, new tab, link): let the resolver build from the URL.
    final raw = currentHistoryState();
    final ownFloor = _floorKind(raw); // this entry's OWN kind (a kept floor)
    final blob = _canonBlob(raw);
    if (ownFloor == FloorKind.kept && blob != null) {
      // Refreshing AT the kept floor: one entry, restore its launch stack.
      _serial = (blob['serialCount'] as num?)?.toInt() ?? 0;
      _floor = FloorKind.kept;
      _floorUrl = bootUrl;
      _suppressReport = true;
      restore((blob['s'] as Map).cast<String, Object?>());
      _suppressReport = false;
      _browserUrls = [bootUrl!];
      _browserBack = 0;
    } else if (blob != null) {
      // Refreshing AT a nav entry: adopt the floor below + rebuild the back-chain
      // from the restored stack's prefixes.
      _serial = (blob['serialCount'] as num?)?.toInt() ?? 0;
      _adoptFloor(blob);
      _suppressReport = true;
      restore((blob['s'] as Map).cast<String, Object?>());
      _suppressReport = false;
      _rebuildTracking();
    } else {
      _pendingUrl = bootUrl; // external cold-start / bare floor → resolver
    }
  }

  /// Unwrap a history entry's stored state to canon's blob `{serialCount, bi, s}`,
  /// or null if it isn't a canon entry. canon writes `serialCount` at top level so
  /// the engine's multi-entry layer treats the entry as already-tagged and never
  /// rewrites canon's data.
  Map<String, Object?>? _canonBlob(Object? state) =>
      state is Map && state['s'] is Map ? state.cast<String, Object?>() : null;

  /// Browser back/forward landed on an entry → canon restores from its blob. This
  /// is the sole input channel (no Router provider); programmatic go(-N) lands here
  /// too (suppress the echo so restore doesn't re-report).
  void _onPopState(Object? state, String url) {
    final kind = _floorKind(state);
    // 1. We walked back to the anchor to complete a divergent switch.
    if (_rebuild != null) {
      delegate._completeRebuild();
      return;
    }
    // 2. A floor entry: we're now at the floor (index 0) — record that so the
    //    next navigation diffs from here. A `fallthrough` floor bounces out
    //    (one-shot: disarm to `sentinel` first); a `sentinel`/`kept` floor stays.
    if (kind != null) {
      _floor = kind;
      _floorUrl = url;
      _browserUrls = [url];
      _browserBack = 0;
      if (kind == FloorKind.kept) {
        // Returnable base: restore its launch snapshot and keep its URL.
        _floorFace = null;
        _suppressReport = true;
        restore(((state as Map)['s'] as Map).cast<String, Object?>());
        _suppressReport = false;
        return;
      }
      // A bare floor: render the consumer's root widget (not the stale stack).
      _floorFace = kind;
      if (kind == FloorKind.fallthrough) {
        _suppressReport = true;
        historyReplace(url, _floorBlob(FloorKind.sentinel)); // disarm before leaving
        _suppressReport = false;
        _floor = FloorKind.sentinel;
        _floorFace = FloorKind.sentinel;
        historyGo(-1); // leave the app; no-op on a fresh tab → the face stays
      }
      delegate._notify(); // show the face (no history write)
      return;
    }
    // 3. A nav entry → restore canon to it; adopt its floor + rebuild the view.
    final blob = _canonBlob(state);
    if (blob == null) return; // foreign/cold entry — resolver owns it
    _serial = (blob['serialCount'] as num?)?.toInt() ?? _serial;
    _floorFace = null;
    _adoptFloor(blob);
    _suppressReport = true;
    restore((blob['s'] as Map).cast<String, Object?>());
    _suppressReport = false;
    _rebuildTracking();
  }

  /// canon's serial counter for history entries (mirrors the engine's multi-entry
  /// serialCount so the engine recognizes our entries and leaves them untouched).
  int _serial = 0;

  /// The URLs of the current browser path canon holds — index 0 is the synthetic
  /// `/` floor when [_hasFloor], then one entry per active stack level. Always the
  /// path to the CURRENT entry (forward entries, left by a back, are the browser's
  /// to restore via popstate). The diff against the next commit drives push/go.
  List<String> _browserUrls = const [];

  /// The kind of floor at index 0 of [_browserUrls], or null when there is none
  /// (the path is bare trunks-down, e.g. `[e, f, g]`). Set when a trunk-switch
  /// introduces a floor; cleared when a deepening navigation kills it.
  FloorKind? _floor;

  /// The floor entry's URL (`/` for a synthetic floor, the launch path for a
  /// `kept` one). Null when [_floor] is null. Stamped into every nav entry's blob
  /// (`fu`/`fk`) so a refresh/land reconstructs the floor from the entry alone —
  /// the rest of the back-chain is just the prefixes of the restored stack.
  String? _floorUrl;

  /// Non-null while sitting on a BARE floor (a `sentinel`/`fallthrough` whose exit
  /// bounce was a no-op — nothing behind to leave to). The delegate then renders
  /// the consumer's root widget instead of the (stale) stack; the base widget reads
  /// it via `Screen.root.kind` to decide what to show. Null during boot-loading too,
  /// so null = "loading", set = "bare floor". Cleared on any real commit or land.
  FloorKind? _floorFace;

  /// The base/floor kind to surface to the consumer's root widget: the bare-floor
  /// face if we're on one, else none. Backs `Screen.root.kind`.
  FloorKind? get rootKind => _floorFace;

  /// The current front screen's widget (the top of the live stack), or null while
  /// booting. A base widget can `return Screen.root.front` to keep showing it.
  Widget? get frontWidget {
    final top = _activeScope.slots.lastOrNull?.entry.screen;
    return top == null || top == BootScreen.root
        ? null
        : (top as WidgetScreen).widget as Widget;
  }

  /// Whether a synthetic floor (made on a trunk-switch) bounces out of the app
  /// via `go(-1)` when it comes to the front. Defaults to true (back from a trunk
  /// exits). Consumer-settable via [rootFallthrough]; canon clears the live
  /// entry's flag to false right before bouncing (one-shot).
  bool _rootFallthrough = true;
  set rootFallthrough(bool v) => _rootFallthrough = v;

  /// The kind a freshly-introduced synthetic floor takes: armed to bounce out by
  /// default, or a quiet sentinel when the consumer has disarmed it.
  FloorKind get _armedKind =>
      _rootFallthrough ? FloorKind.fallthrough : FloorKind.sentinel;

  /// Whether the launch position should be a KEPT floor — a returnable base that
  /// back returns to (then exits) and that trunk-switches stack above instead of
  /// replacing. Declared by [anchor]/[passthrough]; applied at the cold-start
  /// commit. Default false (a launch is a plain base, replaced on a trunk-switch).
  bool _rootKept = false;

  /// Persist the current launch/base position as a returnable floor — back returns
  /// to it then exits, and trunk-switches stack above it. Call from the `base:`
  /// widget for a shareable cold-start destination. Backs `Screen.root.anchor()`.
  void anchor() => _rootKept = true;

  /// Make the launch/base a throwaway that passes through (exits) on back — the
  /// default. Call for a transient cold-start (edit/auth/one-shot) you don't want
  /// to return into. Backs `Screen.root.passthrough()`.
  void passthrough() => _rootKept = false;

  /// A divergent switch (e.g. trunk→trunk) can't write the new path until the
  /// browser has walked back to the shared floor (`go` is async). This holds the
  /// target to rebuild once the landing popstate arrives. Null when idle.
  ({List<String> path, int from, FloorKind? floorKind})? _rebuild;

  /// A history entry's stored payload `{serialCount, bi, s}`. `serialCount` at the
  /// top level makes the engine's multi-entry layer treat the entry as
  /// already-tagged (no rewrite). `bi` = entries behind this one (back-index, for
  /// the pop guard); `s` = canon's nav snapshot — the part canon fully owns.
  Map<String, Object?> _stateBlob(int backIndex, Map<String, Object?> state) => {
        'serialCount': _serial,
        'bi': backIndex,
        's': state,
        if (_floor != null) ...{'fu': _floorUrl, 'fk': _floor!.name},
      };

  /// Recompute the browser-path view from the restored active stack + the floor:
  /// `[floor?] + the URL of each stack prefix`. The whole back-chain is derivable
  /// this way (each entry is one screen deeper than the one below), so a refresh
  /// or a popstate land rebuilds it from the entry alone.
  void _rebuildTracking() {
    _browserUrls = [
      if (_floorUrl != null) _floorUrl!,
      for (var d = 0; d < _activeScope.slots.length; d++) currentUrl(d),
    ];
    _browserBack = _browserUrls.length - 1;
  }

  /// Adopt the floor (`fu`/`fk`) recorded in a landed/refreshed entry's blob.
  void _adoptFloor(Map<String, Object?> blob) {
    final fk = blob['fk'];
    _floor = fk is String ? FloorKind.values.byName(fk) : null;
    _floorUrl = _floor != null ? blob['fu'] as String? : null;
  }

  /// A synthetic floor entry's payload: `floor` = its [FloorKind] (no nav
  /// snapshot — the consumer's `base` widget renders it).
  Map<String, Object?> _floorBlob(FloorKind kind) =>
      {'serialCount': _serial, 'floor': kind.name};

  /// A kept floor's payload: a floor (returnable, never killed) that ALSO carries
  /// its nav snapshot `s`, so back returns to and re-renders the launch position.
  Map<String, Object?> _keptBlob(Map<String, Object?> state) =>
      {'serialCount': _serial, 'floor': FloorKind.kept.name, 's': state};

  /// The [FloorKind] stored in a history entry's state, or null if it isn't a
  /// floor (a nav entry carries `s` instead).
  static FloorKind? _floorKind(Object? state) =>
      state is Map && state['floor'] is String
          ? FloorKind.values.byName(state['floor'] as String)
          : null;

  final NavSpec spec;

  /// The runtime link tree assembled from every `.link`/widget-form branch in the
  /// tree (trunk-level and nested, path-prefixed by their nav ancestors), or null
  /// if the tree declares no links. The matcher walks it; host-agnostic (origin
  /// is supplied per parse).
  late final LinkNode? _linkRoot;

  // Wrap [inner] in a chain of static segs for [ancestors] (outermost first), so
  // a nested link carries its placement path (`profile` > `user` > slot).
  static LinkTreeNode _prefix(List<String> ancestors, LinkTreeNode inner) {
    var node = inner;
    for (final name in ancestors.reversed) {
      node = SegBuilder.forScreen(name)..children = {node};
    }
    return node;
  }

  static LinkNode? _linkRootOf(Set<TreeNode> trunkScreens, NavSpec spec) {
    final branches = <LinkTreeNode>{};
    // Root-level links sit directly in the tree set (no enclosing placement).
    for (final r in trunkScreens) {
      if (r is LinkBranch) branches.add(r.node);
    }
    // Nested links ride a placement; walk the canonical tree for their ancestors.
    void visit(GrammarNode node, List<String> ancestors) {
      final here = [...ancestors, node.screen.name];
      for (final link in node.links) {
        if (link is LinkBranch) {
          // `.link` on some screen, placed in this node's set → URL is this
          // node's full path, then the link's own (screen-rooted) subtree.
          branches.add(_prefix(here, link.node));
        } else if (link is LinkTreeNode) {
          // Bare `slots`/`slot` in this screen's children = the WIDGET form: add
          // the screen seg and inject its id codec as an extra union branch.
          final id = node.screen is ScreenNodeBase
              ? (node.screen as ScreenNodeBase).id
              : null;
          final leaf = id != null && link is SlotBuilder
              ? link.withIdBranch(id)
              : link;
          branches.add(
              _prefix(ancestors, SegBuilder.forScreen(node.screen.name)..children = {leaf}));
        }
      }
      for (final child in node.children) {
        visit(child, here);
      }
    }

    for (final trunk in spec.trunks) {
      visit(trunk, const []);
    }
    return branches.isEmpty ? null : linkRoot(branches);
  }

  /// Parses [url] against the tree's `.links` grammar — PATH-ONLY: the host is
  /// captured (reported back), never used as a match constraint (the platform's
  /// link verification already proved it's ours). Returns the runtime match, or
  /// null when the URL isn't a representable link. `Screen.parseLink` retypes it.
  LinkMatch? parseLink(String url) {
    final trunk = _linkRoot;
    if (trunk == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    // The domain is derived from the url itself (host is captured, not matched),
    // so it self-matches. A path-only boot/deep-link url ("/item/me") has no
    // scheme/host — an empty prefix yields an empty-scheme/host domain that the
    // matcher compares structurally, instead of `Uri.parse('://')` throwing.
    final prefix = uri.hasScheme ? '${uri.scheme}://${uri.host}' : '';
    return LinkMatcher(LinkSpec([DomainNode(prefix, trunk)])).parse(url);
  }

  /// Encodes a link's [template] (e.g. `user/*`) + ordered slot [values] (and,
  /// per slot, the union codec [branches]) into a full URL under [domain] — the
  /// inverse of [parseLink]. `Screen.toUri` maps a typed `Link` to this.
  String encodeLink(
      String domain, String template, List<Object?> values, List<int> branches,
      [Map<String, Object?> query = const {},
      Map<String, Object?> fragment = const {}]) {
    final linkSpec = LinkSpec([DomainNode(domain, _linkRoot!)]);
    return LinkMatcher(linkSpec).printRoute(
        template: template,
        path: values,
        branches: branches,
        query: query,
        fragment: fragment);
  }

  /// Encodes a nav path — the ordered [screens] from trunk to target, each with
  /// its [ids] entry (null for an id-free or inherited-bare segment) — into the
  /// nav-mirror URL under [domain]. The static counterpart of [currentUrl]: it
  /// builds the SAME `/a/b/<id>` shape from an explicit chain, not the live
  /// stack, so a typed `WidgetLink` can print its URL without navigating. Each
  /// id round-trips through its codec (a value the parser would reject throws).
  String encodeNavUrl(String domain, List<Enum> screens, List<Object?> ids,
      [Map<String, Object?> query = const {},
      Map<String, Object?> fragment = const {}]) {
    final parts = <String>[];
    for (var i = 0; i < screens.length; i++) {
      final s = screens[i];
      parts.add(_urlKebab(s.name));
      final codec = (s as ScreenNodeBase).id;
      if (codec != null && ids[i] != null) {
        final token = codec.encode(ids[i]);
        if (codec.decode(token) == null) {
          throw ArgumentError.value(ids[i], '${s.name} id',
              'is not valid for its codec — toUri() would produce an unparseable URL');
        }
        parts.add(Uri.encodeComponent(token));
      }
    }
    final base = '$domain/${parts.join('/')}';
    // View-state mirrors onto the TARGET (last) screen, exactly like currentUrl.
    final schema = _viewSchema[screens.last];
    final q = schema == null ? '' : _encodeViewMap(schema.query, query);
    final f = schema == null ? '' : _encodeViewMap(schema.fragment, fragment);
    return base + (q.isEmpty ? '' : '?$q') + (f.isEmpty ? '' : '#$f');
  }

  /// Builds a page for a screen's [widget] (already resolved to the owner's
  /// non-null widget; the screen + id are in `ctx.entry`).
  final Page<void> Function(Widget widget, PageCtx ctx, LocalKey key) pageOf;
  final List<NavigatorObserver> Function() _observers;

  /// Screen-name → screen, for restore. Names are unique (refs collapse to one
  /// owner), so this is total over the live tree.
  late final Map<String, Enum> _byName = {
    for (final s in spec.screens) s.name: s,
  };

  late final NavDelegate delegate;

  /// A standalone nav host for `MaterialApp(home: ...)` — no Router, no
  /// RouteInformation channel (URLs/deep-links never drive the stack). Owns
  /// system back and snapshot restoration (always on; [restorationId] is the
  /// stable storage key, override only to avoid a collision).
  Widget manager({String restorationId = 'nav'}) =>
      ScreenManager._(this, restorationId);

  final Map<Enum, _Scope> _scopes = {};

  /// Visited trunks in spec order — IndexedStack children stay stable.
  final List<Enum> _visited = [];
  late Enum _activeTrunk;
  _Sim? _sim;

  /// The consumer's boot loading UI (a `W`), shown for the [BootScreen.root]
  /// entry; null when the graph was seeded from a chain instead.
  Object? _bootWidget;
  final GrammarNode _bootNode = GrammarNode(BootScreen.root);

  /// True while the active top is the synthetic boot placement (pre-first-commit).
  bool get _booting => _activeTrunk == BootScreen.root;

  /// The cold-start URL, set by the web Router before first frame; the generated
  /// `Screen.initialUrl` parses it to a typed `Link?`. Null off the web / warm.
  String? bootUrl;

  /// THE navigation resolver (one, lifetime), wired via the generated
  /// `Screen.resolver = (Link? link) {…}`. Every external link — cold-start web
  /// URL or mobile deep-link, both delivered through [NavDelegate.setNewRoutePath]
  /// — is handed here as a raw url; the generated setter parses it to a `Link?`.
  void Function(String url)? _resolver;

  /// A launch/deep-link url that arrived before a resolver was set — replayed
  /// once when [setResolver] is called. Consume-once: cleared on replay so N
  /// re-assignments never re-fire the same launch link.
  String? _pendingUrl;

  /// The history mode of the last commit — `replace` (Screen.replace.* and the
  /// first commit out of boot) reports a browser history REPLACE so the loading
  /// screen / redirects leave no entry; `push` adds one. Read in [NavDelegate].
  CommitMode _lastCommitMode = .push;

  /// True while applying a browser-initiated route change (back/forward/refresh
  /// restore). The commit must NOT report back to the platform — the browser
  /// already moved within its own history; re-reporting would wipe the forward
  /// stack. Set around [restore] in [NavDelegate.setNewRoutePath].
  bool _suppressReport = false;

  /// Count of browser history entries behind the current one that canon pushed
  /// (so a future `pop` knows whether there's an entry to `history.go(-1)` into
  /// vs. having to synthesize the parent). Grows on push, shrinks on back.
  int _browserBack = 0;

  /// Installs the single resolver (last-wins) and replays the pending launch url
  /// once, if one arrived first (the host fed a cold URL before the resolver was
  /// set). Never disposed — lives the app lifetime.
  void setResolver(void Function(String url) fn) {
    _resolver = fn;
    final pending = _pendingUrl;
    if (pending != null) {
      _pendingUrl = null;
      fn(pending);
    }
  }

  /// Per-screen view-state schema (`screen(...).query/.fragment`): key → codec
  /// (null = flag), split into the query and fragment URL parts.
  final Map<Enum,
          ({Map<String, Codec<Object?>?> query, Map<String, Codec<Object?>?> fragment})>
      _viewSchema = {};

  /// Per-screen live view-state values (screen → key → value). Persisted in
  /// [toState], mirrored into the URL query/fragment of the active top.
  final Map<Enum, Map<String, Object?>> _viewValues = {};

  void _collectViewSchema() {
    void visit(GrammarNode n) {
      if (n.viewQuery.isNotEmpty || n.viewFragment.isNotEmpty) {
        _viewSchema[n.screen] = (query: n.viewQuery, fragment: n.viewFragment);
      }
      n.children.forEach(visit);
    }

    spec.trunks.forEach(visit);
  }

  /// The current value of view-state [key] on [screen] (null = unset/default).
  @internal
  Object? viewGet(Enum screen, String key) => _viewValues[screen]?[key];

  /// Sets view-state [key] on [screen] and re-reports the URL (a historyless
  /// mirror — no stack change, no listeners; the widget that set it owns its own
  /// rebuild). Null clears it (absent ⟺ default, per the round-trip rule).
  @internal
  void viewSet(Enum screen, String key, Object? value) {
    final map = _viewValues[screen] ??= {};
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
    delegate._refresh();
  }

  /// Flattened view-state for the reactive [_ViewModel]: `q:screen.key` /
  /// `f:screen.key` → value, across every screen (so a parked tab's widgets read
  /// their own view-state too).
  Map<String, Object?> viewSnapshot() {
    final out = <String, Object?>{};
    for (final e in _viewSchema.entries) {
      final vals = _viewValues[e.key] ?? const {};
      for (final k in e.value.query.keys) {
        out['q:${e.key.name}.$k'] = vals[k];
      }
      for (final k in e.value.fragment.keys) {
        out['f:${e.key.name}.$k'] = vals[k];
      }
    }
    return out;
  }

  /// The active top screen's query (or fragment) values — the context-free read
  /// alongside `Screen.at`/`.on`/`.stack`. [part] is `'q'` or `'f'`.
  @internal
  Map<String, Object?> activeView(String part) {
    final top = _activeScope.slots.last.entry.screen;
    final schema = _viewSchema[top];
    if (schema == null) return const {};
    final keys = part == 'f' ? schema.fragment.keys : schema.query.keys;
    final vals = _viewValues[top] ?? const {};
    return {for (final k in keys) if (vals[k] != null) k: vals[k]};
  }

  // The codec for a view-state key (query or fragment); null for a flag/unknown.
  Codec<Object?>? _viewCodec(Enum screen, String key) {
    final s = _viewSchema[screen];
    return s == null ? null : (s.query[key] ?? s.fragment[key]);
  }

  // Encodes a screen's view-state for one URL part (`k=v&flag`), omitting unset
  // values (absent ⟺ default).
  String _encodeView(Enum screen, Map<String, Codec<Object?>?>? schema) =>
      _encodeViewMap(schema, _viewValues[screen]);

  // Encodes explicit view [vals] against a [schema] into a `k=v&flag` part —
  // the static counterpart of reading the live store. Used by `encodeNavUrl` so
  // a typed link can carry view-state it was handed, not the current screen's.
  String _encodeViewMap(
      Map<String, Codec<Object?>?>? schema, Map<String, Object?>? vals) {
    if (schema == null || vals == null) return '';
    final pairs = <String>[];
    for (final e in schema.entries) {
      final v = vals[e.key];
      if (v == null) continue;
      final codec = e.value;
      if (codec == null) {
        if (v == true) pairs.add(e.key); // flag: present = true
      } else {
        pairs.add('${e.key}=${Uri.encodeQueryComponent(codec.encode(v))}');
      }
    }
    return pairs.join('&');
  }

  // Decodes a `k=v&flag` URL part into a screen's view-state (codec-rejected
  // values are skipped, not fatal — view-state is best-effort like the mirror).
  void _decodeView(Enum screen, Map<String, Codec<Object?>?>? schema, String raw) {
    if (schema == null || raw.isEmpty) return;
    final map = _viewValues[screen] ??= {};
    for (final pair in raw.split('&')) {
      final eq = pair.indexOf('=');
      final key = eq < 0 ? pair : pair.substring(0, eq);
      final codec = schema[key];
      if (!schema.containsKey(key)) continue;
      if (codec == null) {
        map[key] = true; // flag present
      } else if (eq >= 0) {
        final decoded = codec.decode(Uri.decodeQueryComponent(pair.substring(eq + 1)));
        if (decoded != null) map[key] = decoded;
      }
    }
  }

  bool _scheduled = false;
  late final Nav _nav = Nav._(this);
  final _navListeners = <void Function(Enum from, Enum to)>[];
  final StreamController<Navigation> _navStream =
      StreamController<Navigation>.broadcast();

  Enum get current => _activeScope.slots.last.entry.screen;

  /// A broadcast stream of committed [Navigation] snapshots — the ergonomic
  /// observer surface. Filter with `.where`, dispose via the subscription's
  /// `cancel`. Delivery is async (a post-commit microtask), so it never blocks
  /// the commit; for synchronous commit-phase side effects use [observe].
  Stream<Navigation> get navigations => _navStream.stream;

  /// Registers a SYNCHRONOUS side-effect listener fired AFTER each navigation
  /// commits (new top settled), BEFORE its transition animates. Returns a
  /// disposer. Prefer [navigations] unless you need commit-phase synchronicity.
  VoidCallback observe(void Function(Enum from, Enum to) fn) {
    _navListeners.add(fn);
    return () => _navListeners.remove(fn);
  }


  Navigation _buildNavigation(
          List<StackEntry> fromStack, List<StackEntry> toStack, CommitMode mode) =>
      Navigation(
        from: [for (final e in fromStack) (e.screen, e.id)],
        to: [for (final e in toStack) (e.screen, e.id)],
        mode: mode,
      );

  /// Set by the generated `Screen.replace` before the chain's gos. The NEXT
  /// commit this turn consumes it (its [Navigation.mode] becomes [replace]); if
  /// the chain short-circuits with no commit (`Screen.replace.on(.x)?` missed),
  /// a microtask drops it so it can never leak into a later navigation.
  bool _pendingReplace = false;

  /// Marks the batching navigation as a history [CommitMode.replace] rather than
  /// a push. Inert on the bare stack engine (no history); the web Router delegate
  /// reads [Navigation.mode] to `replaceState`.
  @internal
  void markReplace() {
    _pendingReplace = true;
    scheduleMicrotask(() => _pendingReplace = false);
  }

  // Fold a pending replace into [sim] at the first commit of the turn.
  void _consumeReplace(_Sim sim) {
    if (!_pendingReplace) return;
    sim.mode = .replace;
    _pendingReplace = false;
  }

  /// Canonical encoding of the live tree's shape — the generator emits the same
  /// string from source, so a mismatch flags stale codegen.
  String get structureSignature => spec.structureSignature;

  /// The full multi-scope nav state as a restoration-serializable tree (only
  /// primitives/Lists/Maps), keyed by screen NAME with each id encoded via the
  /// screen's own codec (`ScreenNodeBase.id`). Pairs with [restore].
  // TODO(web): add a monotonic history index here ('i': _historyIndex++) and read
  // it back in `restore`/`setNewRoutePath`. The blob is truth, but with no index
  // we cannot tell a BACK landing from a FORWARD one, nor detect a bfcache restore
  // (browser serving a cached page without a fresh setNewRoutePath). The index lets
  // the delegate diff prev-vs-incoming to classify the transition and to no-op a
  // redundant report. Bump on every commit; persist in the blob so it survives
  // refresh. Only meaningful on web — verify with a live back/forward + bfcache run.
  Map<String, Object?> toState({int? activeDepth}) => {
        'v': structureSignature, // stale-graph guard: reject restore on mismatch
        'active': _activeTrunk.name,
        if (_viewValues.values.any((m) => m.isNotEmpty))
          'views': {
            for (final e in _viewValues.entries)
              if (e.value.isNotEmpty)
                e.key.name: {
                  for (final kv in e.value.entries)
                    kv.key: _viewCodec(e.key, kv.key)?.encode(kv.value) ?? kv.value,
                },
          },
        'scopes': {
          // The synthetic boot scope has no persistable state and no real screen.
          for (final e in _scopes.entries)
            if (e.key != BootScreen.root)
              e.key.name: [
                for (final s in (activeDepth != null && e.key == _activeTrunk
                    ? e.value.slots.take(activeDepth)
                    : e.value.slots))
                  [
                    s.entry.screen.name,
                    (s.entry.screen as ScreenNodeBase).id?.encode(s.entry.id),
                  ],
              ],
        },
      };

  /// Rebuilds every scope from a [toState] snapshot, best-effort: replays legal
  /// edges and decodes each id via the screen's codec. ANY failure mid-stack —
  /// illegal edge, unknown screen, or a token the codec rejects — TRUNCATES the
  /// stack there (the failed screen and everything above it, its descendants,
  /// are dropped), keeping the valid prefix below. Returns false (no mutation)
  /// on a stale-graph snapshot or when nothing is restorable.
  bool restore(Map<String, Object?> state) {
    if (state['v'] != structureSignature) return false;
    final scopes = state['scopes'];
    if (scopes is! Map) return false;
    final built = <Enum, _Scope>{};
    for (final entry in scopes.entries) {
      final trunk = _byName[entry.key];
      final rows = entry.value;
      if (trunk == null || !spec.canonical.containsKey(trunk) || rows is! List) {
        continue;
      }
      final scope = _Scope();
      var node = spec.canonical[trunk]!;
      Enum? from;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        if (row is! List || row.isEmpty) break;
        final screen = _byName[row[0]];
        if (screen == null) break; // unknown screen → truncate
        if (i > 0) {
          final next = spec.edge(node, screen);
          if (next == null) break; // illegal edge → truncate
          node = next;
        }
        final codec = (screen as ScreenNodeBase).id;
        Object? id;
        if (codec != null) {
          final token = row.length > 1 ? row[1] : null;
          // id-bearing screen with a missing or codec-rejected token: drop it
          // AND everything above (its descendants can't outlive it).
          if (token is! String) break;
          id = codec.decode(token);
          if (id == null) break;
        }
        final se = StackEntry(node, id);
        scope.slots.add(_Slot(se, _buildPage(se, animate: false, from: from)));
        from = screen;
      }
      if (scope.slots.isNotEmpty) built[trunk] = scope;
    }
    if (built.isEmpty) return false; // nothing restorable → keep current state
    _scopes
      ..clear()
      ..addAll(built);
    _visited
      ..clear()
      ..addAll(built.keys)
      ..sort((a, b) => a.index.compareTo(b.index));
    final active = _byName[state['active']];
    _activeTrunk =
        (active != null && built.containsKey(active)) ? active : built.keys.first;
    // Rebuild view-state (decode each token via its codec; flags are raw bools).
    _viewValues.clear();
    final views = state['views'];
    if (views is Map) {
      for (final e in views.entries) {
        final screen = _byName[e.key];
        final vals = e.value;
        if (screen == null || vals is! Map) continue;
        final map = _viewValues[screen] ??= {};
        for (final kv in vals.entries) {
          final codec = _viewCodec(screen, kv.key as String);
          if (codec == null) {
            map[kv.key as String] = kv.value;
          } else if (kv.value is String) {
            final d = codec.decode(kv.value as String);
            if (d != null) map[kv.key as String] = d;
          }
        }
      }
    }
    delegate._refresh();
    return true;
  }

  /// The in-session **nav-mirror URL** derived from the ACTIVE scope: each
  /// placement a kebab segment, each id a token via the screen's own codec
  /// (`/account/42`, `/home/settings/about`). Lossy (parked tabs aren't in it) but
  /// cold-start-capable. `/` while booting. The web Router reports this to the bar.
  String currentUrl([int? topIdx]) {
    final slots = _activeScope.slots;
    final ti = topIdx ?? slots.length - 1;
    final top = slots[ti].entry;
    // While booting (Initial), the URL is the pending launch URL the user
    // arrived on — not '/'. The resolver hasn't committed yet; keep what the
    // browser shows so the loading screen reflects where you're headed.
    if (top.screen == BootScreen.root) return bootUrl ?? '/';
    // The URL mirrors the TOP screen's forward grammar path (+ ids), NOT the raw
    // stack: back-edges (.stacked/.cycled) add stack DEPTH, never URL segments.
    // Walk the top's resolved parent chain (trunk→top); each id comes from the
    // deepest stack entry instantiating that spine node (so back-edge depth and
    // sibling-stacked instances below the spine drop out — `[a,b,a]` → `/a`).
    final spine = <GrammarNode>[];
    for (GrammarNode? n = top.node.resolved; n != null; n = n.parent) {
      spine.insert(0, n);
    }
    final parts = <String>[];
    for (final node in spine) {
      parts.add(_urlKebab(node.screen.name));
      final codec = (node.screen as ScreenNodeBase).id;
      // Inherited segments are bare — their id already rode the source segment.
      if (codec != null && node.inheritsFrom == null) {
        Object? id;
        for (var k = 0; k <= ti; k++) {
          if (slots[k].entry.node.resolved == node) id = slots[k].entry.id;
        }
        if (id != null) parts.add(codec.encode(id));
      }
    }
    final base = '/${parts.join('/')}';
    // The active top's view-state mirrors into ?query / #fragment.
    final schema = _viewSchema[top.screen];
    final q = schema == null ? '' : _encodeView(top.screen, schema.query);
    final f = schema == null ? '' : _encodeView(top.screen, schema.fragment);
    return base + (q.isEmpty ? '' : '?$q') + (f.isEmpty ? '' : '#$f');
  }

  /// Reconciles the ACTIVE scope to a nav-mirror [url] (the inverse of
  /// [currentUrl]) — cold-load / back-forward landing. Best-effort, exactly like
  /// [restore]: replays legal edges and decodes ids, TRUNCATING at the first
  /// illegal edge / unknown screen / codec-rejected token (keeping the valid
  /// prefix). Returns false (no mutation) when nothing is representable.
  /// Parse a nav-mirror URL into its trunk-down `(screen, id)` chain, or null if
  /// it doesn't resolve to a legal stack path. Pure (no commit) — the generated
  /// `parseUrl` wraps the result as a go-able `Place`. Truncation rules match
  /// [applyUrl]: unknown screen / illegal edge / rejected-or-missing id ends it.
  List<(Enum, Object?)>? parsePath(String url) {
    final segs = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return null;
    final trunk = _byName[_urlUnkebab(segs.first)];
    if (trunk == null || !spec.canonical.containsKey(trunk)) return null;
    final chain = <(Enum, Object?)>[];
    var node = spec.canonical[trunk]!;
    var i = 0;
    while (i < segs.length) {
      final screen = _byName[_urlUnkebab(segs[i])];
      if (screen == null) break;
      if (chain.isNotEmpty) {
        final next = spec.edge(node, screen);
        if (next == null) break;
        node = next;
      }
      i++;
      final codec = (screen as ScreenNodeBase).id;
      Object? id;
      if (codec != null) {
        if (node.inheritsFrom != null) {
          final src = chain.where((e) => e.$1 == node.inheritsFrom).lastOrNull;
          if (src == null) break;
          id = src.$2;
        } else {
          if (i >= segs.length) break;
          id = codec.decode(segs[i]);
          if (id == null) break;
          i++;
        }
      }
      chain.add((screen, id));
    }
    return chain.isEmpty ? null : chain;
  }

  bool applyUrl(String url) {
    final segs =
        Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return false;
    final trunk = _byName[_urlUnkebab(segs.first)];
    if (trunk == null || !spec.canonical.containsKey(trunk)) return false;
    final scope = _Scope();
    var node = spec.canonical[trunk]!;
    Enum? from;
    var i = 0;
    while (i < segs.length) {
      final screen = _byName[_urlUnkebab(segs[i])];
      if (screen == null) break; // unknown screen → truncate
      if (scope.slots.isNotEmpty) {
        final next = spec.edge(node, screen);
        if (next == null) break; // illegal edge → truncate
        node = next;
      }
      i++;
      final codec = (screen as ScreenNodeBase).id;
      Object? id;
      if (codec != null) {
        if (node.inheritsFrom != null) {
          // Inherited: no URL token — reuse the source segment's id from below.
          final src = scope.slots
              .where((s) => s.entry.screen == node.inheritsFrom)
              .lastOrNull;
          if (src == null) break; // source not on the stack → truncate
          id = src.entry.id;
        } else {
          if (i >= segs.length) break; // id-bearing screen needs a token
          id = codec.decode(segs[i]);
          if (id == null) break; // codec rejected → truncate
          i++;
        }
      }
      final se = StackEntry(node, id);
      scope.slots.add(_Slot(se, _buildPage(se, animate: false, from: from)));
      from = screen;
    }
    if (scope.slots.isEmpty) return false;
    _scopes[trunk] = scope;
    if (!_visited.contains(trunk)) {
      _visited
        ..add(trunk)
        ..sort((a, b) => a.index.compareTo(b.index));
    }
    _activeTrunk = trunk;
    _scopes.remove(BootScreen.root);
    _visited.remove(BootScreen.root);
    // Decode the top screen's view-state from ?query / #fragment.
    final top = scope.slots.last.entry.screen;
    final schema = _viewSchema[top];
    if (schema != null) {
      final uri = Uri.parse(url);
      _viewValues.remove(top);
      _decodeView(top, schema.query, uri.query);
      _decodeView(top, schema.fragment, uri.fragment);
    }
    delegate._refresh();
    return true;
  }

  List<StackEntry> get stack =>
      List.unmodifiable([for (final s in _activeScope.slots) s.entry]);

  /// How many entries on the active stack are [screen] (and [id] if given) —
  /// the cycle depth backing `Screen.on(.x.depth(n))`.
  int countOf(Enum screen, [Object? id]) {
    var n = 0;
    for (final s in _activeScope.slots) {
      if (s.entry.screen == screen && (id == null || s.entry.id == id)) n++;
    }
    return n;
  }

  /// The live placement path of the active top, trunk-first.
  List<Enum> get currentChain {
    final node =
        (_sim?.stack.last ?? _activeScope.slots.last.entry).node.resolved;
    final chain = <Enum>[];
    for (GrammarNode? n = node; n != null; n = n.parent) {
      chain.insert(0, n.screen);
    }
    return chain;
  }

  _Scope get _activeScope => _scopes[_activeTrunk]!;

  StackEntry _seed(Enum trunk, [Object? id]) =>
      StackEntry(spec.canonical[trunk]!, id);

  _Scope _scopeOf(Enum trunk, [Object? id]) => _scopes.putIfAbsent(trunk, () {
        _visited.add(trunk);
        _visited.sort((a, b) => a.index.compareTo(b.index));
        return _Scope()
          ..slots.add(_Slot(_seed(trunk, id),
              _buildPage(_seed(trunk, id), animate: false, from: null)));
      });

  _Sim _ensureSim() => _sim ??= _Sim(
        {
          for (final e in _scopes.entries)
            e.key: [for (final s in e.value.slots) s.entry]
        },
        _activeTrunk,
      );

  @internal
  Nav go<T>(Enum screen, [T? id, bool edgeRequired = false]) {
    assert(
        id != null || null is T || T == Never, '"${screen.name}" requires an id');
    final sim = _ensureSim();
    // Idempotent: going to the current top with the same id is a no-op — no
    // commit, no history entry, no rebuild (so re-tapping the active tab does
    // nothing). Checked before consuming any replace flag so a chain's later
    // segment still sees it. Boot is excluded — the first commit must run.
    if (sim.active != BootScreen.root &&
        sim.stack.isNotEmpty &&
        sim.stack.last.screen == screen &&
        sim.stack.last.id == id) {
      return _nav;
    }
    _consumeReplace(sim);
    final target = screen;
    if (sim.active == BootScreen.root) {
      // First commit out of boot: drop the boot entry, seed the target's trunk
      // fresh, and force replace — the loading screen leaves no history. The
      // resolver stays cold/warm-unaware (it just writes `Screen.goX()`).
      final trunk = spec.trunkOf(target);
      sim.stacks.remove(BootScreen.root);
      sim.active = trunk;
      sim.stacks[trunk] = [_seed(trunk, id)];
      sim.mode = .replace;
      if (target != trunk) {
        _apply(sim,
            resolveGo(spec, sim.stack, target, id, onCanonicalFallback: _warnCanonical));
      } else {
        _schedule();
      }
      return _nav;
    }
    if (edgeRequired) {
      if (sim.stack.isEmpty || spec.edge(sim.stack.last.node, target) == null) {
        final from =
            sim.stack.isEmpty ? 'an empty stack' : sim.stack.last.screen.name;
        _sim = null;
        throw StateError(
            'cannot go to "${target.name}" from "$from" — not a reachable edge (stale handle?)');
      }
      _apply(sim, resolveGo(spec, sim.stack, target, id));
      return _nav;
    }
    final trunk = spec.trunkOf(target);
    if (trunk != sim.active) {
      // Leaving a tab with no keep resets it; a tab with any keep parks.
      if (!spec.retains(sim.active)) {
        sim.stacks[sim.active] = [_seed(sim.active)];
      }
      sim.active = trunk;
      final seeded = sim.stacks.putIfAbsent(trunk, () => [_seed(trunk, id)]);
      if (id != null && seeded.first.id != id) {
        sim.stacks[trunk] = [_seed(trunk, id)];
      }
      if (target == trunk) {
        _schedule();
        return _nav;
      }
    }
    final res =
        resolveGo(spec, sim.stack, target, id, onCanonicalFallback: _warnCanonical);
    _apply(sim, res);
    return _nav;
  }

  /// A guaranteed pop — the caller has proven the target is reachable, so failing
  /// is a generator/programmer error, asserted in debug. Chainable.
  @internal
  Nav pop([Enum? until]) {
    // On web, a single pop IS a browser-back: consume the history entry via
    // `history.go(-1)` so popstate restores the parent blob — no new entry, no
    // accumulation. Targeted pops (until != null) still fall through to a diff.
    if (until == null && _ownsHistory && !_booting && _browserBack > 0) {
      historyGo(-1); // popstate restores the parent blob + its back-index
      return _nav;
    }
    final sim = _ensureSim();
    _consumeReplace(sim);
    final res = resolvePop(sim.stack, until);
    if (res == null) {
      _sim = null;
      throw StateError(
          'pop(${until?.name ?? ''}) is impossible from ${sim.stack.map((e) => e.screen.name)} — guard unprovable pops with Screen.canPop');
    }
    _apply(sim, res);
    return _nav;
  }

  /// Pop the pending sim back to [until] if it's buried — a NO-OP when it's
  /// already the front. Sim-aware (batch-safe), so the generated smart verb
  /// `at(.x)?.goChild()` (pop-to-self-if-needed, then go) batches into one diff.
  @internal
  Nav popTo(Enum until) {
    final sim = _ensureSim();
    if (sim.stack.isNotEmpty && sim.stack.last.screen == until) return _nav;
    final res = resolvePop(sim.stack, until);
    if (res == null) {
      _sim = null;
      throw StateError('popTo(${until.name}) — not reachable on the live stack');
    }
    _apply(sim, res);
    return _nav;
  }

  /// Frees a parked [keep]: cuts the keep and everything above it from its tab's
  /// stack, leaving the legal prefix below (or the bare trunk). Throws if the keep
  /// isn't mounted, or if it's in the currently active stack — forget is
  /// parked-only scope maintenance, not a pop. Not chainable.
  @internal
  void forget(Enum keep) {
    assert(spec.keeps.contains(keep), '"${keep.name}" is not a keep');
    final sim = _ensureSim();
    final trunk = spec.trunkOf(keep);
    if (trunk == sim.active) {
      _sim = null;
      throw StateError(
          'cannot forget "${keep.name}" — it is in the currently active stack');
    }
    final stack = sim.stacks[trunk];
    final idx = stack == null ? -1 : stack.indexWhere((e) => e.screen == keep);
    if (idx < 0) {
      _sim = null;
      throw StateError('cannot forget "${keep.name}" — it is not mounted');
    }
    final cut = stack!.sublist(0, idx);
    sim.stacks[trunk] = cut.isEmpty ? [_seed(trunk)] : cut;
    _schedule();
  }

  void _apply(_Sim sim, NavResolution res) {
    final stack = sim.stack;
    stack.removeRange(stack.length - res.popCount, stack.length);
    stack.addAll(res.pushes);
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(_commit);
  }

  void _commit() {
    final sim = _sim;
    _scheduled = false;
    _sim = null;
    if (sim == null) return;
    _floorFace = null; // a real navigation supersedes any bare-floor face
    final fromEntry = _activeScope.slots.last.entry;
    final fromStack = [for (final s in _activeScope.slots) s.entry];
    for (final entry in sim.stacks.entries) {
      final scope = _scopeOf(entry.key);
      final target = entry.value;
      final from = scope.slots.isNotEmpty ? scope.slots.last.entry.screen : null;
      var common = 0;
      while (common < scope.slots.length &&
          common < target.length &&
          identical(scope.slots[common].entry, target[common])) {
        common++;
      }
      if (common == scope.slots.length && common == target.length) continue;
      scope.slots.removeRange(common, scope.slots.length);
      for (var i = common; i < target.length; i++) {
        scope.slots.add(_Slot(
          target[i],
          _buildPage(
            target[i],
            animate: entry.key == sim.active && i == target.length - 1,
            from: i == common ? from : target[i - 1].screen,
          ),
        ));
      }
    }
    _activeTrunk = sim.active;
    _scopeOf(_activeTrunk);
    final toEntry = _activeScope.slots.last.entry;
    if (!identical(fromEntry, toEntry)) {
      _lastCommitMode = sim.mode;
      final nav = _buildNavigation(
          fromStack, [for (final s in _activeScope.slots) s.entry], sim.mode);
      for (final fn in [..._navListeners]) {
        fn(fromEntry.screen, toEntry.screen);
      }
      if (_navStream.hasListener) _navStream.add(nav);
    }
    // First commit out of boot: drop the now-parked boot scope so its loading
    // widget unmounts and never re-renders.
    if (_activeTrunk != BootScreen.root && _scopes.containsKey(BootScreen.root)) {
      _scopes.remove(BootScreen.root);
      _visited.remove(BootScreen.root);
    }
    delegate._refresh();
  }

  Page<void> _buildPage(StackEntry entry,
      {required bool animate, required Enum? from}) {
    final screen = entry.screen;
    // canon owns the ScreenScope wrap, so the raw entry/id never reaches pageOf.
    final widget = screen == BootScreen.root
        ? _bootWidget as Widget
        : (screen as WidgetScreen).widget as Widget;
    final content = ScreenScope(entry: entry, child: widget);
    return pageOf(
      content,
      PageCtx(screen, animate: animate, from: from),
      screen == BootScreen.root
          ? const ValueKey('__boot__')
          : spec.isMulti(screen)
              ? UniqueKey()
              : ValueKey(screen.name),
    );
  }

  // The active Navigator removed a page on its own (gesture / system back).
  void _onPageRemoved(Page<void> page) {
    for (final scope in _scopes.values) {
      scope.slots.removeWhere((s) => identical(s.page, page));
    }
  }

  void _warnCanonical(String message) {
    assert(() {
      debugPrint('[nav] $message');
      return true;
    }());
  }
}

final class NavDelegate extends RouterDelegate<Object>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<Object> {
  NavDelegate._(this._graph);

  final NavGraph _graph;

  @override
  GlobalKey<NavigatorState> get navigatorKey => _graph._activeScope.navKey;

  void _notify() => notifyListeners();

  @override
  Widget build(BuildContext context) {
    // On a bare floor (a bounce that found nothing behind), the live stack is
    // stale — show the consumer's root widget, which reads `Screen.root.kind`.
    if (_graph._floorFace != null) return _graph._bootWidget as Widget;
    final visited = _graph._visited;
    return _ViewModel(
      snapshot: _graph.viewSnapshot(),
      child: _PlacementModel(
        chain: _graph.currentChain.toSet(),
        top: _graph.current,
        child: _buildStack(visited),
      ),
    );
  }

  Widget _buildStack(List<Enum> visited) {
    return IndexedStack(
      index: visited.indexOf(_graph._activeTrunk),
      children: [
        for (final trunk in visited)
          _ScopeLiveness(
            active: trunk == _graph._activeTrunk,
            kept: _graph.spec.keptWhenParked,
            child: TickerMode(
              enabled: trunk == _graph._activeTrunk,
              child: HeroControllerScope(
                controller: _graph._scopes[trunk]!.hero,
                child: Navigator(
                  key: _graph._scopes[trunk]!.navKey,
                  observers: _graph._observers(),
                  pages: [for (final s in _graph._scopes[trunk]!.slots) s.page],
                  onDidRemovePage: _graph._onPageRemoved,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Null: canon drives the browser History API directly in [_refresh], so the
  /// framework must not auto-report. Input arrives via canon's own popstate
  /// listener, not the Router.
  @override
  RouteInformation? get currentConfiguration => null;

  /// Cold-load / back / forward / refresh land here. Blob present (back/forward/
  /// refresh) → restore it (truth). Blob absent (pasted/external cold URL) → the
  /// nav-mirror reconcile (truncate-to-valid-prefix); a declared LINK is resolved
  /// by the consumer's resolver off `Screen.initialUrl`, not here.
  @override
  Future<void> setNewRoutePath(Object configuration) {
    if (configuration is RouteInformation) {
      final state = configuration.state;
      if (state is Map && state['s'] is Map) {
        // Blob present (back/forward/refresh) → restore the nav-mirror (truth).
        // `{bi, s}`: adopt the back-index, restore the snapshot. Browser-initiated:
        // suppress the report so the forward stack survives.
        _graph._suppressReport = true;
        _graph._browserBack = (state['bi'] as num?)?.toInt() ?? _graph._browserBack;
        _graph.restore((state['s'] as Map).cast<String, Object?>());
        _graph._suppressReport = false;
      } else {
        // Blob absent = an EXTERNAL link: a cold-start web URL or a mobile
        // deep-link (Flutter routes both here). Record it for `Screen.initialUrl`
        // and hand it to the single resolver — which writes `Screen.goX()`. With
        // no resolver installed, fall back to the nav-mirror reconcile.
        final url = configuration.uri.toString();
        if (_graph._booting) _graph.bootUrl = url;
        if (_graph._resolver != null) {
          _graph._resolver!(url);
        } else {
          // No resolver installed: stash the launch url for one set later, and
          // keep the legacy nav-mirror reconcile (a declared link is a no-op).
          if (_graph._booting) _graph._pendingUrl = url;
          _graph.applyUrl(url);
        }
      }
    }
    return SynchronousFuture(null);
  }

  void _refresh() {
    // Write the browser history directly. `_suppressReport` is set while restoring
    // from a popstate landing, so we don't re-report what the browser just told us.
    // Off-web / booting: nothing to write.
    if (_graph._ownsHistory && !_graph._booting && !_graph._suppressReport) {
      final n = _graph._activeScope.slots.length;
      final canon = [for (var d = 0; d < n; d++) _graph.currentUrl(d)];
      final prev = _graph._browserUrls;

      if (prev.isEmpty) {
        // Cold-start. `anchor()` → a kept floor (one returnable entry at the
        // launch URL; trunk-switches stack above it). Otherwise a plain base (its
        // levels are entries; back past index 0 exits). Deep non-kept cold-start
        // as a multi-level path is TODO.
        if (_graph._rootKept) {
          _graph._floor = FloorKind.kept;
          _graph._floorUrl = canon.last;
          historyReplace(canon.last, _graph._keptBlob(_graph.toState()));
          _graph._browserUrls = [canon.last];
          _graph._browserBack = 0;
        } else {
          // One entry showing the front (a cold-start can't fan into back-
          // navigable entries on web — they'd be gesture-less/skippable).
          historyReplace(canon.last, _graph._stateBlob(0, _graph.toState()));
          _graph._browserUrls = [canon.last];
          _graph._browserBack = 0;
        }
        notifyListeners();
        return;
      }
      if (_graph._lastCommitMode == CommitMode.replace) {
        // Screen.replace.* — redirect: overwrite the current top, no new history.
        final eff = [if (_graph._floor != null) prev[0], ...canon];
        historyReplace(eff.last, _navBlob(eff, eff.length - 1));
        _graph._browserUrls = eff;
        _graph._browserBack = eff.length - 1;
        notifyListeners();
        return;
      }

      // Decide the target browser path + where to start writing it + whether index
      // 0 is a floor. A killable floor (fallthrough/sentinel) is dropped the moment
      // a navigation gives us ≥2 levels to re-base on (the push truncates forward);
      // a kept floor and the depth-1 case keep a floor.
      final killable = _graph._floor != null && _graph._floor != FloorKind.kept;
      late final List<String> path;
      late final int from;
      late final FloorKind? floorKind;

      if (killable && canon.length >= 2) {
        path = canon; // re-base bare at index 0, floor gone
        from = 0;
        floorKind = null;
      } else {
        final eff = [if (_graph._floor != null) prev[0], ...canon];
        var common = 0;
        while (common < prev.length && common < eff.length && prev[common] == eff[common]) {
          common++;
        }
        if (common == prev.length && common == eff.length) {
          notifyListeners();
          return; // identical
        }
        if (common == eff.length && prev.length > eff.length) {
          historyGo(-(prev.length - eff.length)); // pure pop
          notifyListeners();
          return;
        }
        if (common == prev.length) {
          path = eff; // extension
          from = common;
          floorKind = _graph._floor;
        } else if (common == 0) {
          // Root-switch (no floor shared). ≥2 levels → re-base bare; a bare trunk →
          // introduce a floor (can't truncate a single entry to one cleanly).
          if (canon.length >= 2) {
            path = canon;
            from = 0;
            floorKind = null;
          } else {
            path = ['/', ...canon];
            from = 0;
            floorKind = _graph._armedKind;
          }
        } else {
          path = eff; // partial divergence: keep shared prefix, rebuild the tail
          from = common;
          floorKind = _graph._floor;
        }
      }

      _graph._rebuild = (path: path, from: from, floorKind: floorKind);
      final toIndex = from == 0 ? 0 : from - 1;
      final back = prev.length - 1 - toIndex;
      if (back > 0) {
        historyGo(-back);
      } else {
        _completeRebuild();
      }
    }
    notifyListeners();
  }

  /// The nav-entry blob for browser index [i] of path [eff]: its nav depth is the
  /// index minus the floor offset.
  Map<String, Object?> _navBlob(List<String> eff, int i) {
    final navLevel = i - (_graph._floor != null ? 1 : 0);
    return _graph._stateBlob(i, _graph.toState(activeDepth: navLevel + 1));
  }

  /// Build `path[from..]` after the browser has walked back to the anchor (index
  /// `from-1`, or index 0 when `from == 0`). The first write replaces (consumes
  /// the bottom) only when `from == 0`; the rest push (truncating stale forward).
  void _completeRebuild() {
    final r = _graph._rebuild!;
    _graph._rebuild = null;
    _graph._floor = r.floorKind;
    _graph._floorUrl = r.floorKind != null ? r.path.first : null;
    for (var i = r.from; i < r.path.length; i++) {
      final blob = i == 0 && r.floorKind != null
          ? _graph._floorBlob(r.floorKind!)
          : _navBlob(r.path, i);
      if (i == r.from && r.from == 0) {
        historyReplace(r.path[i], blob);
      } else {
        _graph._serial++;
        historyPush(r.path[i], blob);
      }
    }
    _graph._browserUrls = r.path;
    _graph._browserBack = r.path.length - 1;
  }
}

/// Parses incoming browser [RouteInformation] for the Router. Pass-through: the
/// blob/URL split is decided in [NavDelegate.setNewRoutePath]. Pair with
/// `Screen.delegate` under `MaterialApp.router`.
final class CanonRouteParser extends RouteInformationParser<Object> {
  const CanonRouteParser();

  @override
  Future<Object> parseRouteInformation(RouteInformation information) =>
      SynchronousFuture(information);

  @override
  RouteInformation? restoreRouteInformation(Object configuration) =>
      configuration is RouteInformation ? configuration : null;
}

/// Drop into `MaterialApp(home: ...)` via `Screen.manager()`. Hosts the same
/// nav tree as the delegate but with no Router/RouteInformation channel, so URLs
/// and deep-links can't drive the stack — handle links imperatively. Owns system
/// back; with a restorationId, persists/restores the snapshot (no URLs).
final class ScreenManager extends StatelessWidget {
  const ScreenManager._(this._graph, this._restorationId);

  final NavGraph _graph;
  final String _restorationId;

  @override
  Widget build(BuildContext context) => RootRestorationScope(
        restorationId: _restorationId,
        child: _ManagerBody(_graph),
      );
}

class _ManagerBody extends StatefulWidget {
  const _ManagerBody(this.graph);

  final NavGraph graph;

  @override
  State<_ManagerBody> createState() => _ManagerBodyState();
}

class _ManagerBodyState extends State<_ManagerBody>
    with RestorationMixin, WidgetsBindingObserver {
  final RestorableStringN _snap = RestorableStringN(null);
  VoidCallback? _off;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  // Routes system back to the active scope's navigator (no Router needed).
  @override
  Future<bool> didPopRoute() => widget.graph.delegate.popRoute();

  @override
  String? get restorationId => 'canon_nav';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_snap, 'stack');
    final s = _snap.value;
    if (s != null) {
      widget.graph.restore(jsonDecode(s) as Map<String, Object?>);
    }
    _off ??= widget.graph
        .observe((_, __) => _snap.value = jsonEncode(widget.graph.toState()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _off?.call();
    _snap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.graph.delegate;
    return AnimatedBuilder(
      animation: d,
      builder: (context, _) => d.build(context),
    );
  }
}
