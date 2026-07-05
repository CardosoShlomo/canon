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

import 'link_dsl.dart';

/// The host-facing face of a screen: its widget — NULLABLE, and never forced:
/// a row with no widget is a LINK-ONLY row (grammar/URL presence, nothing to
/// render; nav verbs to it are the generator's concern to omit). The engine
/// stays Flutter-free — W is abstract here; the Flutter alias binds it to
/// `Widget`. Lets the host read a widget off an erased (`Enum`) screen; the
/// name comes from `Enum` directly.
abstract interface class WidgetScreen<W> {
  W? get widget;
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

  /// Link branches declared at this placement: a `.link({...})` ([LinkBranch]) or
  /// a bare `slots`/`slot` in children (a [LinkTreeNode] — the WIDGET form, whose
  /// screen id is injected as an extra union branch). Runtime-read by [NavGraph]
  /// to assemble the parse/encode matcher tree; never part of the nav stack.
  final List<TreeNode> links = [];

  /// View-state schema declared via `screen(...).query({...})` / `.fragment({...})`
  /// — key → codec (null codec = a flag). The engine URL-mirrors the stored values
  /// by this; persisted in `toState`, historyless (replaceState) on set.
  Map<String, Codec<Object?>?> viewQuery = const {};
  Map<String, Codec<Object?>?> viewFragment = const {};

  /// The ancestor screen this placement inherits its id from (`.inherit`), or
  /// null. The nav-mirror URL puts the id on the SOURCE only — an inherited
  /// segment is bare (`/item/42/edit-item`, not `…/edit-item/42`).
  Enum? inheritsFrom;

  /// Additional ancestor sources for a COMPOSITE (record) id — each contributes
  /// one component of the id, matched to the source by entity (id type). Empty
  /// for the single-source `inherit(a)` path, which uses [inheritsFrom] alone.
  List<Enum> inheritsAlso = const [];
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
// Not sealed: link DSL nodes (`SlotBuilder`/`SegBuilder`, another library) also
// implement this as `TreeNode<Never>`, so a bare `slots(...)` can sit directly in
// a screen's children — covariance makes `TreeNode<Never>` a child of any screen.
abstract interface class TreeNode<S> {}

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

/// A link-grammar branch placed in the tree (a trunk, or nested in a `.call`).
/// It is GENERATOR-READ ONLY: the runtime nav engine ignores it (links don't
/// seed the stack). Carries the link DSL node the generator walks to emit `Link`.
final class LinkBranch<S> extends TreeNode<S> {
  LinkBranch(this.node);
  final LinkTreeNode node;
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

// The shared placement builder: assembles a GrammarNode from a children set
// and stashes it for its parent (or the graph constructor) to claim. Both
// node tiers ([LinkNode], [ScreenNodeBase]) author through this.
void _placeNode<S>(Enum screen, Set<TreeNode<S>> children,
    {bool keep = false, bool forget = false}) {
  final node = GrammarNode(screen, keep: keep, forget: forget);
  for (final child in children) {
    // Link declarations are not nav placements; stash them on the node for the
    // runtime matcher (a LinkBranch = `.link`; a bare LinkTreeNode = widget form).
    if (child is LinkBranch || child is LinkTreeNode) {
      node.links.add(child);
      continue;
    }
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
}

/// A URL-addressable grammar node with NO presentation and NO fields — the
/// enum NAME is the whole declaration. The links-only tier of the screens
/// grammar: a server or API surface authors
/// `enum _Links with LinkNode<_Links>` and builds the same tree
/// (`user({product})`) with the same link/view-state vocabulary, and nothing
/// to render. A [ScreenNodeBase] row is conceptually a LinkNode plus a
/// widget; the hierarchy unification (placement-as-link, matcher/generator
/// support) is a coming pass — today this is the authoring surface and the
/// validated tree ([LinkGraph]).
mixin LinkNode<S extends LinkNode<S>> on Enum implements TreeNode<S> {
  /// This node's id codec, or null when id-free — an overridable GETTER, so
  /// a links-only enum stays completely field-free.
  Codec<Object?>? get id => null;

  S get _self => this as S;

  /// Declares a placement of this node with [children] as its continuations.
  S call([Set<TreeNode<S>> children = const {}]) {
    _placeNode<S>(this, children);
    return _self;
  }

  /// URL ingress branches (`slot`/nested segs) that resolve to this node.
  LinkBranch<S> links([Set<LinkTreeNode?> children = const {}]) =>
      LinkBranch<S>(SegBuilder.forScreen(name)..children = children);

  /// Singular alias of [links].
  LinkBranch<S> link([Set<LinkTreeNode?> children = const {}]) =>
      links(children);

  /// This placement's `?query` view-state keys — URL-tier, so it lives on
  /// the link tier (a server route's query params are the same declaration).
  S query(Set<QueryTerm> terms) {
    _attachViewTo(this, (n) => n.viewQuery = viewSchema(terms));
    return _self;
  }

  /// Like [query] for the URL `#fragment`.
  S fragment(Set<QueryTerm> terms) {
    _attachViewTo(this, (n) => n.viewFragment = viewSchema(terms));
    return _self;
  }
}

void _attachViewTo(Enum screen, void Function(GrammarNode) apply) {
  for (var i = _stash.length - 1; i >= 0; i--) {
    if (_stash[i].screen == screen && !_stash[i].again) {
      apply(_stash[i]);
      return;
    }
  }
}

mixin ScreenNodeBase<S extends ScreenNodeBase<S, W>, W> on Enum
    implements TreeNode<S>, WidgetScreen<W> {
  /// This screen's widget, or null for a LINK-ONLY row — nothing is forced:
  /// the base grammar node carries no fields. The public `ScreenNode` alias
  /// binds W to `Widget`; the engine stays Flutter-free by keeping it an
  /// abstract type parameter.
  @override
  W? get widget => null;

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
    _placeNode<S>(this, children, keep: keep, forget: forget);
    return _self;
  }

  /// Back-edge that folds a completed duplicate cycle: revisiting the same
  /// (screen, id) block already on the stack pops back to it instead of growing.
  _BackEdge<S> get cycled => _BackEdge<S>(this, collapse: true);

  /// Back-edge that stacks a fresh instance on every revisit, preserving the
  /// intermediate stack (the only guard is the universal no-op when the target
  /// equals the current top).
  _BackEdge<S> get stacked => _BackEdge<S>(this, collapse: false);

  /// Declares this placement's id as its ancestors' (structurally): the generated
  /// push verb takes no id and reads the live ancestor id instead. Read
  /// syntactically by the generator; at runtime stashes an inherit-marked node so
  /// the nav-mirror URL can omit the (duplicate) id on this segment.
  ///
  /// With one [s1] this is the single-source form (the whole id is [s1]'s — or,
  /// when [s1]'s id is composite, the one component matching this screen's
  /// node). With more sources it composes a COMPOSITE id: each ancestor
  /// contributes one component, matched by node; the kick-start verb shrinks to
  /// only the components no ancestor supplies. Arity mirrors `IdNode.compose`:
  /// a composite id has 2–16 components, so up to 16 sources.
  S inherit(S s1,
      [S? s2, S? s3, S? s4, S? s5, S? s6, S? s7, S? s8, S? s9, S? s10, S? s11,
      S? s12, S? s13, S? s14, S? s15, S? s16]) {
    _stash.add(GrammarNode(this)
      ..inheritsFrom = s1
      ..inheritsAlso = [?s2, ?s3, ?s4, ?s5, ?s6, ?s7, ?s8, ?s9, ?s10, ?s11,
          ?s12, ?s13, ?s14, ?s15, ?s16]);
    return _self;
  }

  /// Opens link-world for this screen: declares URL branches (`slot`/nested
  /// segs) that resolve to it. Generator-read; a runtime no-op (links
  /// don't seed the nav stack). Children are link DSL nodes, so `.links` can't
  /// nest — the one-way boundary is enforced by the child type.
  LinkBranch<S> links([Set<LinkTreeNode?> children = const {}]) =>
      LinkBranch<S>(SegBuilder.forScreen(name)..children = children);

  /// Singular alias of [links] — reads naturally for a single union branch:
  /// `user.link({slot(.literal('me') | .uuid(#userId) | .username)})`.
  LinkBranch<S> link([Set<LinkTreeNode?> children = const {}]) => links(children);

  /// Declares this placement's view-state QUERY keys (`feed(...).query({category(
  /// .string), radius(.int)})` → `?category=&radius=`). Screen-local, persisted,
  /// historyless. Keys come from a [QueryKeyBase] enum: `key(codec)` = value, bare
  /// key = flag. Read syntactically by the generator; at runtime attaches the
  /// schema to this placement's node.
  S query(Set<QueryTerm> terms) {
    _attachView((n) => n.viewQuery = viewSchema(terms));
    return _self;
  }

  /// Like [query] but for the URL FRAGMENT (`#message=`). Same key/codec rules.
  S fragment(Set<QueryTerm> terms) {
    _attachView((n) => n.viewFragment = viewSchema(terms));
    return _self;
  }

  void _attachView(void Function(GrammarNode) apply) {
    for (var i = _stash.length - 1; i >= 0; i--) {
      if (_stash[i].screen == this && !_stash[i].again) {
        apply(_stash[i]);
        return;
      }
    }
  }
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
  NavSpec(Set<TreeNode> trunkScreens) {
    try {
      for (final trunk in trunkScreens) {
        if (trunk is LinkBranch) continue; // generator-read only, not a nav trunk
        if (trunk is _BackEdge) {
          throw StateError(
              'a back-edge (${trunk.screen}.${trunk.collapse ? 'cycled' : 'stacked'}) '
              'cannot be a trunk');
        }
        final screen = trunk is _Graft ? trunk.screen : trunk as Enum;
        trunks.add(_takeStash(screen) ?? GrammarNode(screen));
      }
      assert(_stash.isEmpty,
          'unclaimed grammar nodes ${_stash.join(', ')} — structured mentions '
          'that are not elements of their enclosing set');
      _canonicalize();
      for (final trunk in trunks) {
        _index(trunk);
      }
      _validate();
    } finally {
      // A throw never leaks orphan nodes into the next construction.
      _stash.clear();
    }
  }

  final List<GrammarNode> trunks = [];
  final Map<Enum, GrammarNode> canonical = {};
  final Set<Enum> keeps = {};
  final Set<Enum> forgets = {};

  /// Trunks whose subtree contains a keep — i.e. tabs retained when parked.
  final Set<Enum> retainingTrunks = {};
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

    for (final trunk in trunks) {
      gather(trunk);
    }

    final owners = <String, Enum>{};
    for (final entry in byName.entries) {
      // A non-WidgetScreen row (a grafted LinkNode) is widget-less by kind.
      final widgeted = [
        for (final s in entry.value)
          if (s is WidgetScreen && (s as WidgetScreen).widget != null) s
      ];
      if (widgeted.length > 1) {
        throw StateError('screen "${entry.key}" has ${widgeted.length} owners '
            '(${widgeted.join(', ')}) — only one declaration may carry a widget');
      }
      // No widget in the whole name group = a LINK-ONLY row (URL presence,
      // nothing to render) — legal by kind; the first declaration owns it.
      owners[entry.key] = widgeted.isEmpty ? entry.value.first : widgeted.first;
    }

    void rewrite(GrammarNode node) {
      node.screen = owners[node.screen.name]!;
      for (final child in node.children) {
        rewrite(child);
      }
    }

    for (final trunk in trunks) {
      rewrite(trunk);
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
    void check(GrammarNode node, Enum trunk, bool live) {
      node.resolved; // throws when an again has no ancestor
      if (node.keep) {
        if (live) {
          throw StateError('"${node.screen.name}.keep" is redundant — an '
              'ancestor already keeps this region (need a forget between them)');
        }
        keeps.add(node.screen);
        retainingTrunks.add(trunk);
        live = true;
      } else if (node.forget) {
        if (!live) {
          throw StateError('"${node.screen.name}.forget" is redundant — this '
              'region is already not kept (forget only carves inside a keep)');
        }
        forgets.add(node.screen);
        live = false;
      }
      // A LINK-ONLY row (no widget by kind) cannot sit ABOVE presenting rows
      // yet: navigation would have to pass through an unrenderable stack
      // entry. Fail at build until pass-through (stack-skipped URL segment)
      // placement lands.
      final s = node.screen;
      final linkOnly = s is! WidgetScreen || (s as WidgetScreen).widget == null;
      if (linkOnly) {
        for (final child in node.children) {
          final c = child.screen;
          if (c is WidgetScreen && (c as WidgetScreen).widget != null) {
            throw StateError(
                'link-only row "${s.name}" has presenting child '
                '"${c.name}" — navigating through a link-only row is not '
                'supported yet');
          }
        }
      }
      for (final child in node.children) {
        check(child, trunk, live);
      }
    }

    for (final trunk in trunks) {
      check(trunk, trunk.screen, false);
    }
  }

  /// The trunk screen owning [screen]'s scope (its canonical chain's trunk).
  Enum trunkOf(Enum screen) => chainOf(screen).first.screen;

  /// Whether [trunk]'s tab is retained when parked (its subtree has a keep);
  /// a keepless tab is dropped on leave, as before.
  bool retains(Enum trunk) => retainingTrunks.contains(trunk);

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

  /// Canonical chain trunk..screen — the stack recipe for canonical navigation.
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

    return ([for (final r in trunks) ser(r)]..sort()).join(';');
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

/// A live navigation stack, trunk-first: the full record (screens + ids) plus
/// derived views.
final class NavStack<T> {
  const NavStack(this.entries);

  final List<NavEntry<T>> entries;

  /// The top of the stack — where you are now.
  T get current => entries.last.screen;

  /// The id of the top entry.
  Object? get currentId => entries.last.id;

  /// The scope trunk — the tab this stack belongs to.
  T get tab => entries.first.screen;

  /// Every screen, trunk-first.
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
