/// Navigation grammar engine. Pure Dart so the grammar is unit-testable on the
/// VM; the Flutter host lives in nav_graph.dart.
///
/// Consumers declare a spec enum and mix the node behavior in:
///   `enum _Screens with ScreenNode<_Screens> { ... }`
/// The AUTHORING surface stays typed per family (`TreeNode<S>`), so a tree
/// literal rejects foreign screens — except via the explicit `graft`. The
/// RUNTIME engine is identity-based (over `Enum`), so one graph can hold screens
/// grafted from several families.
library;

import 'package:canon_codec/canon_codec.dart';
import 'package:meta/meta.dart';

/// The host-facing face of a screen: its widget. The engine stays Flutter-free —
/// W is abstract here; the Flutter alias binds it to `Widget`. Lets the host read
/// a widget off an erased (`Enum`) screen; the name comes from `Enum` directly.
abstract interface class WidgetScreen<W> {
  W get widget;
}

/// One placement of a screen in the grammar tree. A screen may own several
/// placements; the first-built one is canonical. Identity-based (over `Enum`),
/// so grafted foreign screens compose into one tree.
@internal
final class GrammarNode {
  GrammarNode(this.screen,
      {this.again = false,
      this.keep = false,
      this.forget = false,
      this.collapse = true});

  /// Mutable so the spec can rewrite a ref to its owner (see [NavSpec] —
  /// `_canonicalize`); distinct ref/owner values collapse to one screen.
  Enum screen;
  final bool again;

  /// Liveness-on boundary: this node and its subtree stay live when the tab
  /// parks (inherited downward until a `forget`). A tab with any keep is retained.
  final bool keep;

  /// Liveness-off boundary: within a kept region, this node and its subtree are
  /// freed (rebuilt fresh) when the tab parks (inherited downward until a `keep`).
  final bool forget;

  /// `cycled` back-edge folds a completed duplicate cycle; `stacked` (false)
  /// pushes a fresh instance instead. Only meaningful on back-edges.
  final bool collapse;
  final List<GrammarNode> children = [];
  GrammarNode? parent;

  /// The node whose children answer "what may follow here" — self, or the
  /// nearest same-screen ancestor for `cycled`/`stacked` back-edges.
  GrammarNode get resolved {
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

/// Authoring marker: what a grammar set literal may hold — a screen (via
/// `ScreenNodeBase`), a `cycled`/`stacked` back-edge, or a `graft` of another
/// family. `<S>` keeps a native literal typed to one family; `graft` is the one
/// explicit cross-family bridge.
sealed class TreeNode<S> {}

/// A `cycled`/`stacked` back-edge as a first-class set element. Carries the
/// screen and fold mode; has no methods, so `.cycled.inherit(...)` can't be written.
final class _BackEdge<S> extends TreeNode<S> {
  _BackEdge(this.screen, {required this.collapse});
  final Enum screen;
  final bool collapse;
}

/// A node grafted from another screen family, mounted into this family's tree.
final class _Graft<S> extends TreeNode<S> {
  _Graft(this.screen);
  final Enum screen;
}

// Pending call/keep/forget nodes awaiting their parent. ONE global stash (nodes
// are identity-based now), claimed by screen identity — distinct enum values
// never collide, so a graft claims exactly the foreign node it named.
final List<GrammarNode> _stash = [];

GrammarNode? _takeStash(Enum screen) {
  for (var i = _stash.length - 1; i >= 0; i--) {
    if (_stash[i].screen == screen) return _stash.removeAt(i);
  }
  return null;
}

mixin ScreenNodeBase<S extends ScreenNodeBase<S, W>, W> on Enum
    implements TreeNode<S>, WidgetScreen<W> {
  /// This screen's widget. The public `ScreenNode` alias binds W to `Widget`;
  /// the engine stays Flutter-free by keeping it an abstract type parameter.
  @override
  W get widget;

  /// This screen's id codec, or null when id-free. Declared as a field on the
  /// consumer enum (`final Codec? id;`); the engine reads it to round-trip ids
  /// for restoration — no codegen. The default keeps id-free enums field-free.
  Codec<Object?>? get id => null;

  S get _self => this as S;

  /// Declares a placement of this screen with [children] as its continuations.
  /// Returns the screen itself so tree literals type as Set<TreeNode<S>>.
  S call([Set<TreeNode<S>> children = const {}]) => _place(children);

  /// Liveness-on boundary: this placement and its subtree stay live when the
  /// tab parks (inherited downward until a `forget`). Any keep makes the tab
  /// retained-when-parked.
  S keep([Set<TreeNode<S>> children = const {}]) => _place(children, keep: true);

  /// Liveness-off boundary: within a kept region, this placement and its subtree
  /// are freed (rebuilt fresh) when the tab parks (inherited until a `keep`).
  S forget([Set<TreeNode<S>> children = const {}]) =>
      _place(children, forget: true);

  S _place(Set<TreeNode<S>> children, {bool keep = false, bool forget = false}) {
    final node = GrammarNode(this, keep: keep, forget: forget);
    for (final child in children) {
      // A back-edge carries its own node; a graft claims the foreign node it
      // named; a bare screen claims its stashed call()/keep() node (tail-first,
      // so a nested set never steals an outer sibling's) or is a leaf.
      final GrammarNode childNode;
      if (child is _BackEdge<S>) {
        childNode =
            GrammarNode(child.screen, again: true, collapse: child.collapse);
      } else if (child is _Graft<S>) {
        childNode = _takeStash(child.screen) ?? GrammarNode(child.screen);
      } else {
        final s = child as Enum;
        childNode = _takeStash(s) ?? GrammarNode(s);
      }
      childNode.parent = node;
      node.children.add(childNode);
    }
    _stash.add(node);
    return _self;
  }

  /// Back-edge that folds a completed duplicate cycle: revisiting the same
  /// (screen, id) block already on the stack pops back to it instead of growing.
  _BackEdge<S> get cycled => _BackEdge<S>(this, collapse: true);

  /// Back-edge that stacks a fresh instance on every revisit, preserving the
  /// intermediate stack (the only guard is the universal no-op when the target
  /// equals the current top).
  _BackEdge<S> get stacked => _BackEdge<S>(this, collapse: false);

  /// Declares this placement's id as [ancestor]'s (structurally): the generated
  /// push verb takes no id and reads the live ancestor id instead. Read
  /// syntactically by the generator; a runtime no-op that returns self.
  S inherit(S ancestor) => _self;
}

/// Mounts a [child] from ANOTHER screen family into this family's tree — the one
/// explicit cross-family edge. Pass a screen, a built `Sub.x({...})`, or a
/// reusable `static final subtree`. Inferred [P] (the parent family) comes from
/// the target set's element type; [C] from the grafted node.
TreeNode<P> graft<P, C>(TreeNode<C> child) {
  if (child is! Enum) {
    throw ArgumentError('graft expects a screen or a built node, not $child');
  }
  return _Graft<P>(child as Enum);
}

/// The validated grammar: canonical placements, kinds, and the legality oracle.
@internal
final class NavSpec {
  NavSpec(Set<TreeNode> rootScreens) {
    try {
      for (final root in rootScreens) {
        if (root is _BackEdge) {
          throw StateError(
              'a back-edge (${root.screen}.${root.collapse ? 'cycled' : 'stacked'}) '
              'cannot be a root');
        }
        final screen = root is _Graft ? root.screen : root as Enum;
        roots.add(_takeStash(screen) ?? GrammarNode(screen));
      }
      assert(_stash.isEmpty,
          'unclaimed grammar nodes ${_stash.join(', ')} — structured mentions '
          'that are not elements of their enclosing set');
      _canonicalize();
      for (final root in roots) {
        _index(root);
      }
      _validate();
    } finally {
      // A throw never leaks orphan nodes into the next construction.
      _stash.clear();
    }
  }

  final List<GrammarNode> roots = [];
  final Map<Enum, GrammarNode> canonical = {};
  final Set<Enum> keeps = {};
  final Set<Enum> forgets = {};

  /// Roots whose subtree contains a keep — i.e. tabs retained when parked.
  final Set<Enum> retainingRoots = {};
  final Set<Enum> _againTargets = {};
  final Map<Enum, int> _placements = {};

  /// Collapses refs to their owner. A screen name may be declared once with a
  /// widget (the OWNER) and any number of times with a null widget (REFS, e.g.
  /// a sub-enum's bare row reused for in-family `inherit`/`cycled`). Every node
  /// of that name is rewritten to the owner value, so the engine and host only
  /// ever see one screen identity per name — exactly one owner, no dangling ref.
  void _canonicalize() {
    final byName = <String, Set<Enum>>{};
    void gather(GrammarNode node) {
      (byName[node.screen.name] ??= {}).add(node.screen);
      for (final child in node.children) {
        gather(child);
      }
    }

    for (final root in roots) {
      gather(root);
    }

    final owners = <String, Enum>{};
    for (final entry in byName.entries) {
      final widgeted = [
        for (final s in entry.value)
          if ((s as WidgetScreen).widget != null) s
      ];
      if (widgeted.length > 1) {
        throw StateError('screen "${entry.key}" has ${widgeted.length} owners '
            '(${widgeted.join(', ')}) — only one declaration may carry a widget');
      }
      if (widgeted.isEmpty) {
        throw StateError('screen "${entry.key}" is a ref with no owner — '
            'one same-named declaration must carry the widget');
      }
      owners[entry.key] = widgeted.first;
    }

    void rewrite(GrammarNode node) {
      node.screen = owners[node.screen.name]!;
      for (final child in node.children) {
        rewrite(child);
      }
    }

    for (final root in roots) {
      rewrite(root);
    }
  }

  void _index(GrammarNode node) {
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
    // `live` is the inherited keep/forget state (default: not kept). keep flips
    // it on for the subtree, forget flips it off; a toggle that doesn't change
    // it is redundant — and redundancy is a generation/build error.
    void check(GrammarNode node, Enum root, bool live) {
      node.resolved; // throws when an again has no ancestor
      if (node.keep) {
        if (live) {
          throw StateError('"${node.screen.name}.keep" is redundant — an '
              'ancestor already keeps this region (need a forget between them)');
        }
        keeps.add(node.screen);
        retainingRoots.add(root);
        live = true;
      } else if (node.forget) {
        if (!live) {
          throw StateError('"${node.screen.name}.forget" is redundant — this '
              'region is already not kept (forget only carves inside a keep)');
        }
        forgets.add(node.screen);
        live = false;
      }
      for (final child in node.children) {
        check(child, root, live);
      }
    }

    for (final root in roots) {
      check(root, root.screen, false);
    }
  }

  /// The root screen owning [screen]'s scope (its canonical chain's root).
  Enum rootOf(Enum screen) => chainOf(screen).first.screen;

  /// Whether [root]'s tab is retained when parked (its subtree has a keep);
  /// a keepless tab is dropped on leave, as before.
  bool retains(Enum root) => retainingRoots.contains(root);

  /// Whether [screen]'s placement stays live when its tab parks: its nearest
  /// keep/forget boundary (inclusive) is a keep. Default (no boundary) is not
  /// live, so a parked tab frees everything above its topmost keep.
  bool keptWhenParked(Enum screen) {
    final chain = chainOf(screen);
    for (var i = chain.length - 1; i >= 0; i--) {
      if (chain[i].keep) return true;
      if (chain[i].forget) return false;
    }
    return false;
  }

  Iterable<Enum> get screens => canonical.keys;

  /// Multi-instance screens get unique page keys; singletons keep constant keys.
  bool isMulti(Enum screen) =>
      _againTargets.contains(screen) || (_placements[screen] ?? 0) > 1;

  /// Canonical chain root..screen — the stack recipe for canonical navigation.
  List<GrammarNode> chainOf(Enum screen) {
    final node = canonical[screen];
    if (node == null) {
      throw StateError('screen "${screen.name}" has no placement in the tree');
    }
    final chain = <GrammarNode>[];
    for (GrammarNode? n = node; n != null; n = n.parent) {
      chain.insert(0, n);
    }
    return chain;
  }

  /// The grammar node a push of [target] from [top] adopts, or null if illegal.
  GrammarNode? edge(GrammarNode top, Enum target) {
    for (final child in top.resolved.children) {
      if (child.screen == target) return child.resolved;
    }
    return null;
  }

  /// Whether the edge from [top] to [target] folds completed cycles (`cycled`)
  /// or stacks fresh instances (`stacked`).
  bool edgeCollapses(GrammarNode top, Enum target) {
    for (final child in top.resolved.children) {
      if (child.screen == target) return child.collapse;
    }
    return true;
  }

  /// Order-independent canonical encoding of the tree's shape (names, nesting,
  /// keep/forget/again flags). The generator emits the same encoding from
  /// source; a mismatch means the tree was re-parented without regenerating.
  String get structureSignature {
    String ser(GrammarNode n) {
      final kids = [for (final c in n.children) ser(c)]..sort();
      final flags =
          '${n.keep ? 'K' : ''}${n.forget ? 'F' : ''}${n.again ? 'A' : ''}';
      return '${n.screen.name}$flags(${kids.join(',')})';
    }

    return ([for (final r in roots) ser(r)]..sort()).join(';');
  }
}

/// One page on the runtime stack, as the grammar sees it.
final class StackEntry {
  const StackEntry(this.node, this.id);

  final GrammarNode node;
  final Object? id;

  Enum get screen => node.screen;
}

/// One entry of a live navigation stack — a screen and its id. [T] is the screen
/// representation: the raw `Enum` internally, or the public `Screen<Object?>`
/// wrapper for the consumer-facing stack.
final class NavEntry<T> {
  const NavEntry(this.screen, this.id);

  final T screen;
  final Object? id;
}

/// A live navigation stack, root-first: the full record (screens + ids) plus
/// derived views.
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

  /// Distinct screens, top-first — the legal popTo targets.
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
final class NavResolution {
  const NavResolution({this.popCount = 0, this.pushes = const []});

  final int popCount;
  final List<StackEntry> pushes;
}

bool _matches(StackEntry entry, Enum screen, Object? id) =>
    entry.screen == screen && entry.id == id;

/// The forward verb's ladder: collapse > edge > canonical. Total — canonical
/// always resolves.
@internal
NavResolution resolveGo(
  NavSpec spec,
  List<StackEntry> stack,
  Enum target,
  Object? id, {
  void Function(String)? onCanonicalFallback,
}) {
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
/// top (it survives). Null when impossible.
NavResolution? resolvePop(List<StackEntry> stack, Enum? until) {
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
