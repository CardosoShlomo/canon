/// Navigation grammar engine. Pure Dart so the grammar is unit-testable on the
/// VM; the Flutter host lives in nav_graph.dart.
///
/// Consumers declare a spec enum and mix the node behavior in:
///   `enum _Screens with ScreenNode<Object?, _Screens> { ... }`
/// S is the family type (the enum itself) so the tree literal and the engine
/// stay typed over one screen family.
library;

import 'package:meta/meta.dart';

/// One placement of a screen in the grammar tree. A screen may own several
/// placements; the first-built one is canonical.
@internal
final class GrammarNode<S extends ScreenNodeBase<S, Object>> {
  GrammarNode(this.screen, {this.again = false, this.keep = false, this.collapse = true});

  final S screen;
  final bool again;
  /// Preserved scope root: leaving its stack parks it instead of popping.
  final bool keep;
  /// `cycled` back-edge folds a completed duplicate cycle; `stacked` (false)
  /// pushes a fresh instance instead. Only meaningful on back-edges.
  final bool collapse;
  final List<GrammarNode<S>> children = [];
  GrammarNode<S>? parent;

  /// The node whose children answer "what may follow here" — self, or the
  /// nearest same-screen ancestor for `cycled`/`stacked` back-edges.
  GrammarNode<S> get resolved {
    if (!again) return this;
    for (var n = parent; n != null; n = n.parent) {
      if (n.screen == screen && !n.again) return n;
    }
    throw StateError(
        '"${screen.name}.${collapse ? 'cycled' : 'stacked'}" has no same-screen ancestor');
  }

  @override
  String toString() =>
      again ? '${screen.name}.${collapse ? 'cycled' : 'stacked'}' : screen.name;
}

/// What a grammar set literal may contain: either a screen (the enum, via
/// `ScreenNodeBase`) or a `cycled`/`stacked` back-edge. `sealed` closes the
/// inhabitant set to canon, and the `<S>` pins it to one screen family — so a
/// tree set rejects foreign types, other graphs' screens, and (because a
/// back-edge exposes no methods) any chaining after `.cycled`/`.stacked`.
sealed class TreeNode<S> {}

/// A `cycled`/`stacked` back-edge as a first-class set element (replaces the
/// old per-family stash side-channel). Carries the screen and fold mode; has no
/// methods, so `.cycled.inherit(...)` and the like cannot be written.
final class _BackEdge<S> extends TreeNode<S> {
  _BackEdge(this.screen, {required this.collapse});
  final S screen;
  final bool collapse;
}

// Nodes created by call/keep awaiting their parent. Set literals evaluate
// depth-first left-to-right, so a parent's call() runs after its children's.
// Keyed per family so one enum's nodes can never graft into another's tree.
final Map<Type, List<Object>> _stashes = {};

List<Object> _stashOf(Type family) => _stashes.putIfAbsent(family, () => []);

mixin ScreenNodeBase<S extends ScreenNodeBase<S, W>, W extends Object> on Enum
    implements TreeNode<S> {
  /// This screen's widget. The public `ScreenNode` alias binds W to `Widget`;
  /// the engine stays Flutter-free by keeping it an abstract type parameter.
  W get widget;

  S get _self => this as S;

  /// Declares a placement of this screen with [children] as its continuations.
  /// Returns the screen itself so tree literals type as Set<TreeNode<S>>.
  S call([Set<TreeNode<S>> children = const {}]) => _place(children, keep: false);

  /// A preserved placement: leaving this scope parks its live stack (widgets
  /// retained); returning resumes it as-is. Roots only.
  S keep([Set<TreeNode<S>> children = const {}]) => _place(children, keep: true);

  S _place(Set<TreeNode<S>> children, {required bool keep}) {
    final node = GrammarNode<S>(_self, keep: keep);
    for (final child in children) {
      // A back-edge carries its own node; a screen claims its stashed
      // call()/keep() node (tail-first, so a nested set never steals an outer
      // sibling's) or, if bare, is a leaf.
      final GrammarNode<S> childNode;
      if (child is _BackEdge<S>) {
        childNode = GrammarNode<S>(child.screen, again: true, collapse: child.collapse);
      } else {
        final s = child as S;
        childNode = takeStash<S>(s) ?? GrammarNode<S>(s);
      }
      childNode.parent = node;
      node.children.add(childNode);
    }
    _stashOf(S).add(node);
    return _self;
  }

  /// Back-edge that folds a completed duplicate cycle: revisiting the same
  /// (screen, id) block already on the stack pops back to it instead of growing.
  /// Loops to the nearest same-screen ancestor node.
  _BackEdge<S> get cycled => _BackEdge<S>(_self, collapse: true);

  /// Back-edge that stacks a fresh instance on every revisit, preserving the
  /// intermediate stack (the only guard is the universal no-op when the target
  /// equals the current top). Loops to the nearest same-screen ancestor node.
  _BackEdge<S> get stacked => _BackEdge<S>(_self, collapse: false);

  /// Declares this placement's id as [ancestor]'s (structurally): the generated
  /// push verb takes no id and reads the live ancestor id instead. Read
  /// syntactically by the generator; a runtime no-op that returns self so it
  /// composes in the tree. Lives on the screen (not on a back-edge), so
  /// `.cycled.inherit(...)` is unrepresentable.
  S inherit(S ancestor) => _self;

  static GrammarNode<S>? takeStash<S extends ScreenNodeBase<S, Object>>(S screen) {
    final stash = _stashOf(S);
    for (var i = stash.length - 1; i >= 0; i--) {
      final node = stash[i] as GrammarNode<S>;
      if (node.screen == screen) {
        stash.removeAt(i);
        return node;
      }
    }
    return null;
  }
}

/// The validated grammar: canonical placements, kinds, and the legality oracle.
@internal
final class NavSpec<S extends ScreenNodeBase<S, Object>> {
  NavSpec(Set<TreeNode<S>> rootScreens) {
    final stash = _stashOf(S);
    try {
      for (final root in rootScreens) {
        if (root is _BackEdge<S>) {
          throw StateError(
              'a back-edge (${root.screen}.${root.collapse ? 'cycled' : 'stacked'}) '
              'cannot be a root');
        }
        final screen = root as S;
        roots.add(ScreenNodeBase.takeStash<S>(screen) ?? GrammarNode<S>(screen));
      }
      assert(stash.isEmpty,
          'unclaimed grammar nodes ${stash.join(', ')} — structured mentions '
          'that are not elements of their enclosing set');
      for (final root in roots) {
        _index(root);
      }
      _validate();
    } finally {
      // A throw never leaks orphan nodes into the next construction.
      stash.clear();
    }
  }

  final List<GrammarNode<S>> roots = [];
  final Map<S, GrammarNode<S>> canonical = {};
  final Set<S> keeps = {};
  final Set<S> _againTargets = {};
  final Map<S, int> _placements = {};

  void _index(GrammarNode<S> node) {
    if (node.again) {
      _againTargets.add(node.screen);
      return;
    }
    canonical.putIfAbsent(node.screen, () => node);
    _placements.update(node.screen, (n) => n + 1, ifAbsent: () => 1);
    for (final child in node.children) {
      _index(child);
    }
  }

  void _validate() {
    void check(GrammarNode<S> node) {
      node.resolved; // throws when an again has no ancestor
      if (node.keep && node.parent != null) {
        throw StateError('"${node.screen.name}.keep" must be a root');
      }
      for (final child in node.children) {
        check(child);
      }
    }
    for (final root in roots) {
      check(root);
      if (root.keep) keeps.add(root.screen);
    }
  }

  /// The root screen owning [screen]'s scope (its canonical chain's root).
  S rootOf(S screen) => chainOf(screen).first.screen;

  Iterable<S> get screens => canonical.keys;

  /// Multi-instance screens get unique page keys; singletons keep constant keys.
  bool isMulti(S screen) =>
      _againTargets.contains(screen) || (_placements[screen] ?? 0) > 1;

  /// Canonical chain root..screen — the stack recipe for canonical navigation.
  List<GrammarNode<S>> chainOf(S screen) {
    final node = canonical[screen];
    if (node == null) {
      throw StateError('screen "${screen.name}" has no placement in the tree');
    }
    final chain = <GrammarNode<S>>[];
    for (GrammarNode<S>? n = node; n != null; n = n.parent) {
      chain.insert(0, n);
    }
    return chain;
  }

  /// The grammar node a push of [target] from [top] adopts, or null if illegal.
  GrammarNode<S>? edge(GrammarNode<S> top, S target) {
    for (final child in top.resolved.children) {
      if (child.screen == target) return child.resolved;
    }
    return null;
  }

  /// Whether the edge from [top] to [target] folds completed cycles (`cycled`)
  /// or stacks fresh instances (`stacked`). Reads the back-edge child's own flag,
  /// not its resolved ancestor (which is always a canonical, folding node).
  bool edgeCollapses(GrammarNode<S> top, S target) {
    for (final child in top.resolved.children) {
      if (child.screen == target) return child.collapse;
    }
    return true;
  }

  /// Order-independent canonical encoding of the tree's shape (names, nesting,
  /// keep/again flags). The generator emits the same encoding from source; a
  /// mismatch means the tree was re-parented without regenerating. Sibling order
  /// is normalized out, so cosmetic reorders don't trip it.
  String get structureSignature {
    String ser(GrammarNode<S> n) {
      final kids = [for (final c in n.children) ser(c)]..sort();
      final flags = '${n.keep ? 'K' : ''}${n.again ? 'A' : ''}';
      return '${n.screen.name}$flags(${kids.join(',')})';
    }

    return ([for (final r in roots) ser(r)]..sort()).join(';');
  }
}

/// One page on the runtime stack, as the grammar sees it.
final class StackEntry<S extends ScreenNodeBase<S, Object>> {
  const StackEntry(this.node, this.id);

  final GrammarNode<S> node;
  final Object? id;

  S get screen => node.screen;
}

/// One entry of a live navigation stack — a screen and its id. [T] is the
/// screen representation: the raw spec enum internally, or the public
/// `Screen<Object?>` wrapper for the consumer-facing stack.
final class NavEntry<T> {
  const NavEntry(this.screen, this.id);

  final T screen;
  final Object? id;
}

/// A live navigation stack, root-first: the full record (screens + ids) plus
/// derived views. The one stack type — the engine fills it with raw screens
/// for `onImpossiblePop`, the generated `Screen.stack` fills it with wrappers.
/// Also the per-scope building block restoration serializes.
final class NavStack<T> {
  const NavStack(this.entries);

  final List<NavEntry<T>> entries;

  /// The top of the stack — where you are now.
  T get current => entries.last.screen;

  /// The id of the top entry.
  Object? get currentId => entries.last.id;

  /// The scope root — the tab this stack belongs to.
  T get tab => entries.first.screen;

  /// Every screen, root-first.
  List<T> get screens => [for (final e in entries) e.screen];

  /// Distinct screens, top-first — the legal popTo targets (a popTo reaches
  /// the nearest occurrence, so cycle repetition collapses away). The compact
  /// "where am I / what can I go back to" without losing mixed-cycle screens.
  List<T> get reachable {
    final seen = <T>{};
    return [
      for (var i = entries.length - 1; i >= 0; i--)
        if (seen.add(entries[i].screen)) entries[i].screen,
    ];
  }
}

/// A resolved navigation step: pop [popCount] pages, then push [pushes].
@internal
final class NavResolution<S extends ScreenNodeBase<S, Object>> {
  const NavResolution({this.popCount = 0, this.pushes = const []});

  final int popCount;
  final List<StackEntry<S>> pushes;
}

bool _matches<S extends ScreenNodeBase<S, Object>>(
        StackEntry<S> entry, S screen, Object? id) =>
    entry.screen == screen && entry.id == id;

/// The forward verb's ladder: collapse > edge > canonical. Total — canonical
/// always resolves.
@internal
NavResolution<S> resolveGo<S extends ScreenNodeBase<S, Object>>(
  NavSpec<S> spec,
  List<StackEntry<S>> stack,
  S target,
  Object? id, {
  void Function(String)? onCanonicalFallback,
}) {
  // Repeat-collapse: pushing would complete an immediately repeated block of
  // length p — pop to the block's previous occurrence instead of duplicating.
  // For collapsing edges, p == 1 is the exact-duplicate no-op and p >= 2 folds
  // a completed cycle. A `stacked` back-edge never collapses — it pushes a fresh
  // instance every revisit, even an exact duplicate of the current top.
  final n = stack.length;
  final fold = stack.isEmpty || spec.edgeCollapses(stack.last.node, target);
  for (var p = 1; 2 * p <= n + 1; p++) {
    if (!fold) break;
    if (!_matches(stack[n - p], target, id)) continue;
    var periodic = true;
    for (var i = 0; i < p - 1; i++) {
      final b = stack[n - p + 1 + i];
      if (!_matches(stack[n - 2 * p + 1 + i], b.screen, b.id)) {
        periodic = false;
        break;
      }
    }
    if (periodic) {
      return NavResolution(popCount: p - 1);
    }
  }
  if (stack.isNotEmpty) {
    final node = spec.edge(stack.last.node, target);
    if (node != null) {
      return NavResolution(pushes: [StackEntry(node, id)]);
    }
  }
  final chain = spec.chainOf(target);
  if (chain.length > 1 && stack.isNotEmpty) {
    onCanonicalFallback?.call(
        'go(${target.name}) fell through to canonical from ${stack.last.screen.name} '
        '— missing grammar edge?');
  }
  // Reuse the live prefix, target included — pop only what actually differs.
  var common = 0;
  while (common < chain.length &&
      common < stack.length &&
      identical(stack[common].node, chain[common]) &&
      stack[common].id == (common == chain.length - 1 ? id : null)) {
    common++;
  }
  return NavResolution(
    popCount: stack.length - common,
    pushes: [
      for (var i = common; i < chain.length; i++)
        StackEntry(chain[i], i == chain.length - 1 ? id : null),
    ],
  );
}

/// The reverse verb: pop once, or pop to the nearest [until] STRICTLY BELOW the
/// top (it survives). Skipping the top means popTo of the screen you are on
/// reaches the previous occurrence (self-pop), not a no-op — chain it to step
/// back through a cycle. Null when impossible.
NavResolution<S>? resolvePop<S extends ScreenNodeBase<S, Object>>(
  List<StackEntry<S>> stack,
  S? until,
) {
  if (until == null) {
    return stack.length > 1 ? const NavResolution(popCount: 1) : null;
  }
  for (var i = stack.length - 2; i >= 0; i--) {
    if (stack[i].screen == until) {
      return NavResolution(popCount: stack.length - 1 - i);
    }
  }
  return null;
}
