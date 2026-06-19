import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'screen_node.dart';

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
  const PageCtx(this.entry, {this.animate = true, this.from});

  final StackEntry entry;

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
final class ScreenScope extends StatelessWidget {
  const ScreenScope({super.key, required this.entry, required this.child});

  final StackEntry entry;
  final Widget child;

  static StackEntry of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ScreenEntry>();
    assert(scope != null, 'no ScreenScope above this context');
    return scope!.entry;
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

/// Chain handle: hops queued in one synchronous expression commit together on
/// a microtask — one diff, one animation.
@internal
final class Nav {
  Nav._(this._graph);

  final NavGraph<dynamic> _graph;

  Nav go<T>(Enum screen, [T? id]) => _graph.go(screen, id);

  Nav pop([Enum? until]) => _graph.pop(until);

  bool maybePop([Enum? until]) => _graph.maybePop(until);
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

  List<StackEntry> get stack => stacks[active]!;
}

/// The starting stack, as a pure root..target chain of (screen, id). The
/// generated `InitialScreen` is the only thing implementing this, so `initial:`
/// rejects a navigating `Screen.goX` or a live-stack `Screen.on(...)`.
abstract interface class InitialScreenBase {
  List<(Enum, Object?)> get chain;
}

final class NavGraph<I extends InitialScreenBase> {
  NavGraph(
    Set<TreeNode> rootScreens, {
    required this.pageOf,
    required I initial,
    List<NavigatorObserver> Function()? observers,
  })  : _observers = observers ?? (() => []),
        spec = NavSpec(rootScreens) {
    delegate = NavDelegate._(this);
    final chain = initial.chain;
    _activeRoot = chain.first.$1;
    final scope = _Scope();
    var node = spec.canonical[_activeRoot]!;
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

  /// Builds a page for a screen's [widget] (already resolved to the owner's
  /// non-null widget; the screen + id are in `ctx.entry`).
  final Page<void> Function(Widget widget, PageCtx ctx, LocalKey key) pageOf;
  final List<NavigatorObserver> Function() _observers;

  late final NavDelegate delegate;

  final Map<Enum, _Scope> _scopes = {};

  /// Visited roots in spec order — IndexedStack children stay stable.
  final List<Enum> _visited = [];
  late Enum _activeRoot;
  _Sim? _sim;
  bool _scheduled = false;
  late final Nav _nav = Nav._(this);
  final _navListeners = <void Function(Enum from, Enum to)>[];

  Enum get current => _activeScope.slots.last.entry.screen;

  /// Registers a side-effect listener fired AFTER each navigation commits (the
  /// new top is settled), BEFORE its transition animates. Returns a disposer.
  VoidCallback observe(void Function(Enum from, Enum to) fn) {
    _navListeners.add(fn);
    return () => _navListeners.remove(fn);
  }

  /// Canonical encoding of the live tree's shape — the generator emits the same
  /// string from source, so a mismatch flags stale codegen.
  String get structureSignature => spec.structureSignature;

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

  Nav go<T>(Enum screen, [T? id, bool edgeRequired = false]) {
    assert(
        id != null || null is T || T == Never, '"${screen.name}" requires an id');
    final sim = _ensureSim();
    final target = screen;
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
  Nav pop([Enum? until]) {
    final sim = _ensureSim();
    final res = resolvePop(sim.stack, until);
    if (res == null) {
      _sim = null;
      throw StateError(
          'pop(${until?.name ?? ''}) is impossible from ${sim.stack.map((e) => e.screen.name)} — use maybePop for unprovable pops');
    }
    _apply(sim, res);
    return _nav;
  }

  /// An unprovable pop: pops to [until] (or one level) if possible, else nothing.
  bool maybePop([Enum? until]) {
    final sim = _ensureSim();
    final res = resolvePop(sim.stack, until);
    if (res == null) return false;
    _apply(sim, res);
    return true;
  }

  /// Frees a parked [keep]: cuts the keep and everything above it from its tab's
  /// stack, leaving the legal prefix below (or the bare root). Throws if the keep
  /// isn't mounted, or if it's in the currently active stack — forget is
  /// parked-only scope maintenance, not a pop. Not chainable.
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
    if (!identical(fromEntry, toEntry) && _navListeners.isNotEmpty) {
      for (final fn in [..._navListeners]) {
        fn(fromEntry.screen, toEntry.screen);
      }
    }
    delegate._refresh();
  }

  Page<void> _buildPage(StackEntry entry,
      {required bool animate, required Enum? from}) {
    final screen = entry.screen;
    return pageOf(
      (screen as WidgetScreen).widget as Widget,
      PageCtx(entry, animate: animate, from: from),
      spec.isMulti(screen) ? UniqueKey() : ValueKey(screen.name),
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

  final NavGraph<dynamic> _graph;

  @override
  GlobalKey<NavigatorState> get navigatorKey => _graph._activeScope.navKey;

  @override
  Widget build(BuildContext context) {
    final visited = _graph._visited;
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

  @override
  Future<void> setNewRoutePath(Object configuration) => SynchronousFuture(null);

  void _refresh() => notifyListeners();
}
