import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'screen_node.dart';

/// The spec-enum contract: a screen family carrying the grammar AND a `Widget`.
/// Binds the engine's abstract widget slot to Flutter's `Widget`, so consumers
/// write the clean 2-arg form and `Widget get widget` is required.
///   `enum _Screens with ScreenNode<Object?, _Screens> { ... final Widget widget; }`
typedef ScreenNode<S extends ScreenNodeBase<S, Widget>> = ScreenNodeBase<S, Widget>;

/// The page's grammar identity and transition policy inputs.
final class PageCtx<S extends ScreenNodeBase<S, Object>> {
  const PageCtx(this.entry, {this.animate = true, this.from});

  final StackEntry<S> entry;
  /// False for pages that materialized mid-chain — suppresses their transition.
  final bool animate;
  /// Top screen when this page was pushed.
  final S? from;
}

/// Scopes a page's screen and id to its subtree.
final class ScreenScope<S extends ScreenNodeBase<S, Object>> extends InheritedWidget {
  const ScreenScope({super.key, required this.entry, required super.child});

  final StackEntry<S> entry;

  static StackEntry<S> of<S extends ScreenNodeBase<S, Object>>(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ScreenScope<S>>();
    assert(scope != null, 'no ScreenScope above this context');
    return scope!.entry;
  }

  @override
  bool updateShouldNotify(ScreenScope<S> oldWidget) => false;
}

/// Chain handle: hops queued in one synchronous expression commit together on
/// a microtask — one diff, one animation.
@internal
final class Nav<S extends ScreenNodeBase<S, Object>> {
  Nav._(this._graph);

  final NavGraph<S> _graph;

  Nav<S> go<I>(covariant ScreenNodeBase<S, Object> screen, [I? id]) =>
      _graph.go(screen, id);

  Nav<S> pop([S? until]) => _graph.pop(until);

  bool maybePop([S? until]) => _graph.maybePop(until);
}

class _Slot<S extends ScreenNodeBase<S, Object>> {
  _Slot(this.entry, this.page);

  final StackEntry<S> entry;
  final Page<void> page;
}

/// One live stack: a root screen's pages plus its Navigator identity.
class _Scope<S extends ScreenNodeBase<S, Object>> {
  final List<_Slot<S>> slots = [];
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  final HeroController hero = HeroController();
}

/// The batch's working state: per-scope stacks plus the active scope.
class _Sim<S extends ScreenNodeBase<S, Object>> {
  _Sim(this.stacks, this.active);

  final Map<S, List<StackEntry<S>>> stacks;
  S active;

  List<StackEntry<S>> get stack => stacks[active]!;
}

final class NavGraph<S extends ScreenNodeBase<S, Object>> {
  NavGraph(
    Set<TreeNode<S>> rootScreens, {
    required this.pageOf,
    required S initial,
    List<NavigatorObserver> Function()? observers,
  })  : _observers = observers ?? (() => []),
        spec = NavSpec<S>(rootScreens) {
    delegate = NavDelegate<S>._(this);
    _activeRoot = spec.rootOf(initial);
    _scopeOf(_activeRoot);
  }

  final NavSpec<S> spec;
  final Page<void> Function(S screen, PageCtx<S> ctx, LocalKey key) pageOf;
  final List<NavigatorObserver> Function() _observers;

  late final NavDelegate<S> delegate;

  final Map<S, _Scope<S>> _scopes = {};
  /// Visited roots in spec order — IndexedStack children stay stable.
  final List<S> _visited = [];
  late S _activeRoot;
  _Sim<S>? _sim;
  bool _scheduled = false;
  late final Nav<S> _nav = Nav._(this);
  final _navListeners = <void Function(S from, S to)>[];

  S get current => _activeScope.slots.last.entry.screen;

  /// Registers a side-effect listener fired AFTER each navigation commits (the
  /// new top is settled), BEFORE its transition animates — wire it where your
  /// state lives. Returns a disposer. Pure observation: it cannot veto or
  /// reroute (the destination is already chosen at the call site).
  VoidCallback observe(void Function(S from, S to) fn) {
    _navListeners.add(fn);
    return () => _navListeners.remove(fn);
  }

  /// Canonical encoding of the live tree's shape — the generator emits the same
  /// string from source, so a mismatch flags stale codegen.
  String get structureSignature => spec.structureSignature;

  List<StackEntry<S>> get stack =>
      List.unmodifiable([for (final s in _activeScope.slots) s.entry]);

  /// How many entries on the active stack are [screen] (and [id] if given) —
  /// the cycle depth backing `Screen.on(.x.depth(n))`.
  int countOf(S screen, [Object? id]) {
    var n = 0;
    for (final s in _activeScope.slots) {
      if (s.entry.screen == screen && (id == null || s.entry.id == id)) n++;
    }
    return n;
  }

  /// The live placement path of the active top, root-first — which placement of
  /// the current screen is active. Reads the simulation mid-chain so generated
  /// `.placement` narrowing resolves against the just-performed go.
  List<S> get currentChain {
    final node =
        (_sim?.stack.last ?? _activeScope.slots.last.entry).node.resolved;
    final chain = <S>[];
    for (GrammarNode<S>? n = node; n != null; n = n.parent) {
      chain.insert(0, n.screen);
    }
    return chain;
  }

  _Scope<S> get _activeScope => _scopes[_activeRoot]!;

  StackEntry<S> _seed(S root) => StackEntry(spec.canonical[root]!, null);

  _Scope<S> _scopeOf(S root) => _scopes.putIfAbsent(root, () {
        _visited.add(root);
        _visited.sort((a, b) => a.index.compareTo(b.index));
        return _Scope<S>()..slots.add(_Slot(_seed(root), _buildPage(_seed(root), animate: false, from: null)));
      });

  _Sim<S> _ensureSim() => _sim ??= _Sim(
        {for (final e in _scopes.entries) e.key: [for (final s in e.value.slots) s.entry]},
        _activeRoot,
      );

  Nav<S> go<I>(ScreenNodeBase<S, Object> screen, [I? id, bool edgeRequired = false]) {
    assert(id != null || null is I || I == Never, '"${screen.name}" requires an id');
    final sim = _ensureSim();
    final target = screen as S;
    // A position-anchored verb (a narrowed handle) demands a live edge: a
    // stale-but-still-legal target resolves, a stale-and-unreachable one throws
    // rather than silently teleporting via the canonical fallback.
    if (edgeRequired) {
      if (sim.stack.isEmpty || spec.edge(sim.stack.last.node, target) == null) {
        final from = sim.stack.isEmpty ? 'an empty stack' : sim.stack.last.screen.name;
        _sim = null; // discard the pending batch — nothing commits
        throw StateError(
            'cannot go to "${target.name}" from "$from" — not a reachable edge (stale handle?)');
      }
      _apply(sim, resolveGo<S>(spec, sim.stack, target, id));
      return _nav;
    }
    final root = spec.rootOf(target);
    if (root != sim.active) {
      // Leaving a non-kept scope resets it; a kept scope parks untouched.
      if (!spec.keeps.contains(sim.active)) {
        sim.stacks[sim.active] = [_seed(sim.active)];
      }
      sim.active = root;
      sim.stacks.putIfAbsent(root, () => [_seed(root)]);
      // Switching to the root itself resumes the stack as-is; the ladder
      // only runs when the hop continues deeper. A repeat go (no switch)
      // still collapses canonically.
      if (target == root) {
        _schedule();
        return _nav;
      }
    }
    final res = resolveGo<S>(spec, sim.stack, target, id,
        onCanonicalFallback: _warnCanonical);
    _apply(sim, res);
    return _nav;
  }

  /// A guaranteed pop — the caller (a generated guaranteed verb) has proven the
  /// target is reachable, so failing is a generator/programmer error, asserted
  /// in debug. Chainable.
  Nav<S> pop([S? until]) {
    final sim = _ensureSim();
    final res = resolvePop<S>(sim.stack, until);
    if (res == null) {
      _sim = null; // discard the pending batch — nothing commits
      throw StateError(
          'pop(${until?.name ?? ''}) is impossible from ${sim.stack.map((e) => e.screen.name)} — use maybePop for unprovable pops');
    }
    _apply(sim, res);
    return _nav;
  }

  /// An unprovable pop: pops to [until] (or one level) if possible, else does
  /// nothing. Returns whether it popped. The bool replaces a pop exception.
  bool maybePop([S? until]) {
    final sim = _ensureSim();
    final res = resolvePop<S>(sim.stack, until);
    if (res == null) return false;
    _apply(sim, res);
    return true;
  }

  /// Collapses [screen]'s scope to its bare root without navigating — parked
  /// or active. Scope maintenance, deliberately not chainable.
  void reset(S screen) {
    final sim = _ensureSim();
    final root = spec.rootOf(screen);
    sim.stacks[root] = [_seed(root)];
    _schedule();
  }

  void _apply(_Sim<S> sim, NavResolution<S> res) {
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

  Page<void> _buildPage(StackEntry<S> entry, {required bool animate, required S? from}) {
    final screen = entry.screen;
    return pageOf(
      screen,
      PageCtx<S>(entry, animate: animate, from: from),
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

final class NavDelegate<S extends ScreenNodeBase<S, Object>> extends RouterDelegate<Object>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<Object> {
  NavDelegate._(this._graph);

  final NavGraph<S> _graph;

  @override
  GlobalKey<NavigatorState> get navigatorKey => _graph._activeScope.navKey;

  @override
  Widget build(BuildContext context) {
    final visited = _graph._visited;
    return IndexedStack(
      index: visited.indexOf(_graph._activeRoot),
      children: [
        for (final root in visited)
          TickerMode(
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
      ],
    );
  }

  @override
  Future<void> setNewRoutePath(Object configuration) => SynchronousFuture(null);

  void _refresh() => notifyListeners();
}
