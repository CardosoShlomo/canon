import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show MaterialPage;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import 'package:canon_codec/canon_codec.dart';

import 'link_dsl.dart';
import 'link_matcher.dart';
import 'link_spec.dart';
import 'screen_node.dart';

/// Default page when the consumer gives no `pageOf`: a platform Material page.
Page<void> _defaultPageOf(Widget widget, PageCtx ctx, LocalKey key) =>
    MaterialPage<void>(key: key, child: widget);

/// The shape of a committed navigation, derived from the active scope's stack
/// delta: [forward] grew the stack, [backward] shrank it, [roundTrip] did both
/// (a `popTo(...).go(...)` chain), [jump] switched scope/root (a kick-start).
enum NavDirection { forward, backward, roundTrip, jump }

/// How a committed navigation maps to history: [push] adds a new entry,
/// [replace] overwrites the current one (no back-target). Default is [push];
/// the generated `Screen.replace` flips a batch to [replace], and the engine
/// forces [replace] for the first commit out of the boot state. The web Router
/// delegate reads it (`pushState`/`replaceState`); the bare stack engine, which
/// has no history, ignores it.
enum CommitMode { push, replace }

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
  bool get _sameRoot => from.first.$1 == to.first.$1;

  late final int _common = () {
    if (!_sameRoot) return 0;
    var c = 0;
    while (c < from.length && c < to.length && from[c] == to[c]) {
      c++;
    }
    return c;
  }();

  NavDirection get direction {
    if (!_sameRoot) return NavDirection.jump;
    final popped = _common < from.length;
    final pushed = _common < to.length;
    return popped
        ? (pushed ? NavDirection.roundTrip : NavDirection.backward)
        : NavDirection.forward;
  }

  /// The deepest screen both stacks share, above which they diverged; null on a
  /// scope [jump] (no common stack).
  Enum? get pivot => _sameRoot && _common > 0 ? from[_common - 1].$1 : null;

  /// Screens left behind (popped above the pivot), bottom-to-top.
  List<Enum> get popped =>
      _sameRoot ? [for (var i = _common; i < from.length; i++) from[i].$1] : const [];

  /// Screens entered (pushed above the pivot), bottom-to-top.
  List<Enum> get pushed =>
      _sameRoot ? [for (var i = _common; i < to.length; i++) to[i].$1] : const [];

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
/// widget). Sub-enums mix this in; the root keeps [ScreenNode] (widget required),
/// so the root can never be a ref.
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

/// One live stack: a root screen's pages plus its Navigator identity.
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

/// A direct stack seed (root..target chain of (screen, id)) for the `seedChain:`
/// constructor arg — used by engine/restore code and tests to start at a specific
/// stack. Consumers instead pass `initial:` (the boot widget) and let the resolver
/// drive the first navigation; see [BootScreen].
abstract interface class InitialScreenBase {
  List<(Enum, Object?)> get chain;
}

/// The synthetic boot placement. When a graph is built with a [bootWidget], the
/// stack is seeded as `[(BootScreen.initial, null)]` — so the always-non-empty
/// invariant holds — and `current`/`Screen.at` report it until the first commit,
/// which the engine auto-replaces (the boot entry leaves no history). Never part
/// of a consumer tree; the generated `Screen.at` maps it to `Initial`.
enum BootScreen { initial }

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
    Set<TreeNode> rootScreens, {
    this.pageOf = _defaultPageOf,
    Object? initial,
    InitialScreenBase? seedChain,
    this._observers = _noObservers,
  })  : assert((initial == null) != (seedChain == null),
            'pass exactly one of `initial:` (the boot widget) or `seedChain:`'),
        spec = NavSpec(rootScreens) {
    _linkRoot = _linkRootOf(rootScreens, spec);
    _collectViewSchema();
    delegate = NavDelegate._(this);
    _bootWidget = initial;
    final chain = initial != null
        ? const <(Enum, Object?)>[(BootScreen.initial, null)]
        : seedChain!.chain;
    _activeRoot = chain.first.$1;
    final scope = _Scope();
    var node = initial != null ? _bootNode : spec.canonical[_activeRoot]!;
    Enum? from;
    for (var i = 0; i < chain.length; i++) {
      final (screen, id) = chain[i];
      if (i > 0) {
        node = spec.edge(node, screen) ??
            (throw StateError('invalid initial chain at "${screen.name}"'));
      }
      final entry = StackEntry(node, id);
      scope.slots.add(_Slot(entry, _buildPage(entry, animate: false, from: from)));
      from = screen;
    }
    _scopes[_activeRoot] = scope;
    _visited.add(_activeRoot);
    _visited.sort((a, b) => a.index.compareTo(b.index));
  }

  final NavSpec spec;

  /// The runtime link tree assembled from every `.link`/widget-form branch in the
  /// tree (root-level and nested, path-prefixed by their nav ancestors), or null
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

  static LinkNode? _linkRootOf(Set<TreeNode> rootScreens, NavSpec spec) {
    final branches = <LinkTreeNode>{};
    // Root-level links sit directly in the tree set (no enclosing placement).
    for (final r in rootScreens) {
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

    for (final root in spec.roots) {
      visit(root, const []);
    }
    return branches.isEmpty ? null : linkRoot(branches);
  }

  /// Parses [url] against the tree's `.links` grammar — PATH-ONLY: the host is
  /// captured (reported back), never used as a match constraint (the platform's
  /// link verification already proved it's ours). Returns the runtime match, or
  /// null when the URL isn't a representable link. `Screen.parseLink` retypes it.
  LinkMatch? parseLink(String url) {
    final root = _linkRoot;
    if (root == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final linkSpec = LinkSpec([DomainNode('${uri.scheme}://${uri.host}', root)]);
    return LinkMatcher(linkSpec).parse(url);
  }

  /// Encodes a link's [template] (e.g. `user/*`) + ordered slot [values] (and,
  /// per slot, the union codec [branches]) into a full URL under [domain] — the
  /// inverse of [parseLink]. `Screen.toUri` maps a typed `Link` to this.
  String encodeLink(
      String domain, String template, List<Object?> values, List<int> branches) {
    final linkSpec = LinkSpec([DomainNode(domain, _linkRoot!)]);
    return LinkMatcher(linkSpec)
        .printRoute(template: template, path: values, branches: branches);
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

  /// Visited roots in spec order — IndexedStack children stay stable.
  final List<Enum> _visited = [];
  late Enum _activeRoot;
  _Sim? _sim;

  /// The consumer's boot loading UI (a `W`), shown for the [BootScreen.initial]
  /// entry; null when the graph was seeded from a chain instead.
  Object? _bootWidget;
  final GrammarNode _bootNode = GrammarNode(BootScreen.initial);

  /// True while the active top is the synthetic boot placement (pre-first-commit).
  bool get _booting => _activeRoot == BootScreen.initial;

  /// The cold-start URL, set by the web Router before first frame; the generated
  /// `Screen.initialUrl` parses it to a typed `Link?`. Null off the web / warm.
  String? bootUrl;

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

    spec.roots.forEach(visit);
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
  String _encodeView(Enum screen, Map<String, Codec<Object?>?>? schema) {
    if (schema == null) return '';
    final vals = _viewValues[screen];
    if (vals == null) return '';
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
  Map<String, Object?> toState() => {
        'v': structureSignature, // stale-graph guard: reject restore on mismatch
        'active': _activeRoot.name,
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
          for (final e in _scopes.entries)
            e.key.name: [
              for (final s in e.value.slots)
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
      final root = _byName[entry.key];
      final rows = entry.value;
      if (root == null || !spec.canonical.containsKey(root) || rows is! List) {
        continue;
      }
      final scope = _Scope();
      var node = spec.canonical[root]!;
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
      if (scope.slots.isNotEmpty) built[root] = scope;
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
    _activeRoot =
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
  String currentUrl() {
    final parts = <String>[];
    for (final slot in _activeScope.slots) {
      final e = slot.entry;
      if (e.screen == BootScreen.initial) continue;
      parts.add(_urlKebab(e.screen.name));
      final codec = (e.screen as ScreenNodeBase).id;
      // Inherited segments are bare — their id already rode the source segment.
      if (codec != null && e.id != null && e.node.inheritsFrom == null) {
        parts.add(codec.encode(e.id));
      }
    }
    final base = '/${parts.join('/')}';
    // The active top's view-state mirrors into ?query / #fragment.
    final top = _activeScope.slots.last.entry.screen;
    final schema = _viewSchema[top];
    final q = schema == null ? '' : _encodeView(top, schema.query);
    final f = schema == null ? '' : _encodeView(top, schema.fragment);
    return base + (q.isEmpty ? '' : '?$q') + (f.isEmpty ? '' : '#$f');
  }

  /// Reconciles the ACTIVE scope to a nav-mirror [url] (the inverse of
  /// [currentUrl]) — cold-load / back-forward landing. Best-effort, exactly like
  /// [restore]: replays legal edges and decodes ids, TRUNCATING at the first
  /// illegal edge / unknown screen / codec-rejected token (keeping the valid
  /// prefix). Returns false (no mutation) when nothing is representable.
  bool applyUrl(String url) {
    final segs =
        Uri.parse(url).pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return false;
    final root = _byName[_urlUnkebab(segs.first)];
    if (root == null || !spec.canonical.containsKey(root)) return false;
    final scope = _Scope();
    var node = spec.canonical[root]!;
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
    _scopes[root] = scope;
    if (!_visited.contains(root)) {
      _visited
        ..add(root)
        ..sort((a, b) => a.index.compareTo(b.index));
    }
    _activeRoot = root;
    _scopes.remove(BootScreen.initial);
    _visited.remove(BootScreen.initial);
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

  /// The live placement path of the active top, root-first.
  List<Enum> get currentChain {
    final node =
        (_sim?.stack.last ?? _activeScope.slots.last.entry).node.resolved;
    final chain = <Enum>[];
    for (GrammarNode? n = node; n != null; n = n.parent) {
      chain.insert(0, n.screen);
    }
    return chain;
  }

  _Scope get _activeScope => _scopes[_activeRoot]!;

  StackEntry _seed(Enum root, [Object? id]) =>
      StackEntry(spec.canonical[root]!, id);

  _Scope _scopeOf(Enum root, [Object? id]) => _scopes.putIfAbsent(root, () {
        _visited.add(root);
        _visited.sort((a, b) => a.index.compareTo(b.index));
        return _Scope()
          ..slots.add(_Slot(_seed(root, id),
              _buildPage(_seed(root, id), animate: false, from: null)));
      });

  _Sim _ensureSim() => _sim ??= _Sim(
        {
          for (final e in _scopes.entries)
            e.key: [for (final s in e.value.slots) s.entry]
        },
        _activeRoot,
      );

  @internal
  Nav go<T>(Enum screen, [T? id, bool edgeRequired = false]) {
    assert(
        id != null || null is T || T == Never, '"${screen.name}" requires an id');
    final sim = _ensureSim();
    _consumeReplace(sim);
    final target = screen;
    if (sim.active == BootScreen.initial) {
      // First commit out of boot: drop the boot entry, seed the target's root
      // fresh, and force replace — the loading screen leaves no history. The
      // resolver stays cold/warm-unaware (it just writes `Screen.goX()`).
      final root = spec.rootOf(target);
      sim.stacks.remove(BootScreen.initial);
      sim.active = root;
      sim.stacks[root] = [_seed(root, id)];
      sim.mode = .replace;
      if (target != root) {
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
    final root = spec.rootOf(target);
    if (root != sim.active) {
      // Leaving a tab with no keep resets it; a tab with any keep parks.
      if (!spec.retains(sim.active)) {
        sim.stacks[sim.active] = [_seed(sim.active)];
      }
      sim.active = root;
      final seeded = sim.stacks.putIfAbsent(root, () => [_seed(root, id)]);
      if (id != null && seeded.first.id != id) {
        sim.stacks[root] = [_seed(root, id)];
      }
      if (target == root) {
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

  /// Frees a parked [keep]: cuts the keep and everything above it from its tab's
  /// stack, leaving the legal prefix below (or the bare root). Throws if the keep
  /// isn't mounted, or if it's in the currently active stack — forget is
  /// parked-only scope maintenance, not a pop. Not chainable.
  @internal
  void forget(Enum keep) {
    assert(spec.keeps.contains(keep), '"${keep.name}" is not a keep');
    final sim = _ensureSim();
    final root = spec.rootOf(keep);
    if (root == sim.active) {
      _sim = null;
      throw StateError(
          'cannot forget "${keep.name}" — it is in the currently active stack');
    }
    final stack = sim.stacks[root];
    final idx = stack == null ? -1 : stack.indexWhere((e) => e.screen == keep);
    if (idx < 0) {
      _sim = null;
      throw StateError('cannot forget "${keep.name}" — it is not mounted');
    }
    final cut = stack!.sublist(0, idx);
    sim.stacks[root] = cut.isEmpty ? [_seed(root)] : cut;
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
    _activeRoot = sim.active;
    _scopeOf(_activeRoot);
    final toEntry = _activeScope.slots.last.entry;
    if (!identical(fromEntry, toEntry)) {
      final nav = _buildNavigation(
          fromStack, [for (final s in _activeScope.slots) s.entry], sim.mode);
      for (final fn in [..._navListeners]) {
        fn(fromEntry.screen, toEntry.screen);
      }
      if (_navStream.hasListener) _navStream.add(nav);
    }
    // First commit out of boot: drop the now-parked boot scope so its loading
    // widget unmounts and never re-renders.
    if (_activeRoot != BootScreen.initial && _scopes.containsKey(BootScreen.initial)) {
      _scopes.remove(BootScreen.initial);
      _visited.remove(BootScreen.initial);
    }
    delegate._refresh();
  }

  Page<void> _buildPage(StackEntry entry,
      {required bool animate, required Enum? from}) {
    final screen = entry.screen;
    // canon owns the ScreenScope wrap, so the raw entry/id never reaches pageOf.
    final widget = screen == BootScreen.initial
        ? _bootWidget as Widget
        : (screen as WidgetScreen).widget as Widget;
    final content = ScreenScope(entry: entry, child: widget);
    return pageOf(
      content,
      PageCtx(screen, animate: animate, from: from),
      screen == BootScreen.initial
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

  @override
  Widget build(BuildContext context) {
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
      index: visited.indexOf(_graph._activeRoot),
      children: [
        for (final root in visited)
          _ScopeLiveness(
            active: root == _graph._activeRoot,
            kept: _graph.spec.keptWhenParked,
            child: TickerMode(
              enabled: root == _graph._activeRoot,
              child: HeroControllerScope(
                controller: _graph._scopes[root]!.hero,
                child: Navigator(
                  key: _graph._scopes[root]!.navKey,
                  observers: _graph._observers(),
                  pages: [for (final s in _graph._scopes[root]!.slots) s.page],
                  onDidRemovePage: _graph._onPageRemoved,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Reported to the platform after each commit → the browser URL bar. The
  /// `state` is the blob ([toState]) — TRUTH for back/forward/refresh; the `uri`
  /// is the derived lossy nav-mirror, self-sufficient only on blob-null cold-load.
  @override
  RouteInformation get currentConfiguration => RouteInformation(
        uri: Uri.parse(_graph.currentUrl()),
        state: _graph.toState(),
      );

  /// Cold-load / back / forward / refresh land here. Blob present (back/forward/
  /// refresh) → restore it (truth). Blob absent (pasted/external cold URL) → the
  /// nav-mirror reconcile (truncate-to-valid-prefix); a declared LINK is resolved
  /// by the consumer's resolver off `Screen.initialUrl`, not here.
  @override
  Future<void> setNewRoutePath(Object configuration) {
    if (configuration is RouteInformation) {
      final state = configuration.state;
      if (state is Map<String, Object?>) {
        _graph.restore(state);
      } else {
        // Cold-load: record the URL so the resolver can read `Screen.initialUrl`
        // (a declared LINK), then reconcile the nav-mirror. A link URL won't match
        // `applyUrl` (no mutation) → the app stays at `Initial` for the resolver.
        if (_graph._booting) _graph.bootUrl = configuration.uri.toString();
        _graph.applyUrl(configuration.uri.toString());
      }
    }
    return SynchronousFuture(null);
  }

  void _refresh() => notifyListeners();
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
