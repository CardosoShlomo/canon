import 'package:canon_codec/canon_codec.dart';

/// Marks the hand-written enum that is an app's ENTITY SPACE: each row binds an
/// entity TYPE to its id-NODE, and a `static final graph = EntityGraph({...})`
/// declares OWNERSHIP as a tree — `review({comment})` means a comment belongs
/// to exactly one review (its state lives inside it; removing the review
/// removes its comments by construction). The same child kind may appear under
/// several parents (`image({reactor}), moment({reactor})`): instances still
/// have exactly one owner, of either kind. Roots are the aggregate boundaries —
/// stores attach to roots only.
class Entities {
  const Entities();
}

const entities = Entities();

/// Authoring marker: what an [EntityGraph] set literal may hold — a bare row
/// (a leaf) or a row with children (`review({comment})`).
abstract interface class EntityTreeNode {}

/// The contract an `@entities` enum wears: every row carries the entity [type]
/// and the id-node ([key]) its instances are identified by. `call({children})`
/// declares the row's OWNED children in the graph.
mixin EntityNode<Self extends EntityNode<Self>> on Enum
    implements EntityTreeNode {
  Type get type;

  /// Null = a UNIT entity: cardinality one, keyless — for entities whose
  /// identity is the session (the wire sends their facts without an id).
  IdNode? get key;

  /// This entity with its owned children — `review({comment})`.
  EntityTreeNode call([Set<EntityTreeNode> children = const {}]) =>
      EntityBranch(this, children);

  /// A MERGE EDGE: this row's per-key READ SURFACE consults [source] through
  /// [projection] — `user.merge(viewer, const ViewerSupportsUser())`. The
  /// receiver owns the surface; the source speaks at its own `Identifiable`
  /// id. Chainable (`.merge(a, pa).merge(b, pb)` — resolution in declaration
  /// order), and composes with children: `user.merge(...)({image, moment})`.
  ///
  /// [projection] is a ledger `Projection` — held untyped here (this grammar
  /// sits below the ledger); the generator emits the fully typed wiring.
  EntityMerge merge(Self source, Object projection) =>
      EntityMerge(this, [(source, projection)]);
}

/// A row carrying merge edges (and optionally children) — the tree-building
/// wrapper [EntityNode.merge] returns.
class EntityMerge implements EntityTreeNode {
  EntityMerge(this.entity, this.edges, [this.children = const {}]);

  final Enum entity;
  final List<(Enum, Object)> edges;
  final Set<EntityTreeNode> children;

  EntityMerge merge(Enum source, Object projection) =>
      EntityMerge(entity, [...edges, (source, projection)], children);

  EntityMerge call([Set<EntityTreeNode> children = const {}]) =>
      EntityMerge(entity, edges, children);
}

/// A row plus its owned children — the tree-building wrapper.
class EntityBranch implements EntityTreeNode {
  EntityBranch(this.entity, this.children);
  final Enum entity;
  final Set<EntityTreeNode> children;
}

/// The declared ownership tree. Structure is read both at build time (the
/// generator derives store legality, nested-map machinery, and path types from
/// it) and at runtime ([ownersOf]/[childrenOf] — the entity-scope resolution
/// surface).
class EntityGraph {
  EntityGraph(this.tree) {
    void walk(EntityTreeNode node, Enum? parent) {
      final (row, children) = switch (node) {
        EntityBranch(:final entity, :final children) => (entity, children),
        EntityMerge(:final entity, :final children, :final edges) => () {
            (_merges[entity] ??= []).addAll(edges);
            return (entity, children);
          }(),
        Enum() => (node as Enum, const <EntityTreeNode>{}),
        _ => throw ArgumentError.value(
            node, 'tree', 'not an entity row or branch'),
      };
      if (parent != null) {
        (_owners[row] ??= {}).add(parent);
      } else {
        _roots.add(row);
      }
      for (final c in children) {
        walk(c, row);
      }
    }

    for (final n in tree) {
      walk(n, null);
    }
    for (final r in _roots) {
      if (_owners.containsKey(r)) {
        throw StateError(
            '"${r.name}" is declared both as a root and as an owned child — '
            'an entity kind is either an aggregate root or owned, not both.');
      }
    }
  }

  final Set<EntityTreeNode> tree;
  final Set<Enum> _roots = {};
  final Map<Enum, Set<Enum>> _owners = {};
  final Map<Enum, List<(Enum, Object)>> _merges = {};

  /// The aggregate roots — the rows stores may attach to.
  Set<Enum> get roots => _roots;

  /// The owner KINDS of [row] — empty for a root. An instance is owned by
  /// exactly one instance of one of these.
  Set<Enum> ownersOf(Enum row) => _owners[row] ?? const {};

  /// Whether [row] is an aggregate root (not owned by anything).
  bool isRoot(Enum row) => !_owners.containsKey(row);

  /// The merge edges declared on [row]'s read surface, declaration order:
  /// (source row, projection instance).
  List<(Enum, Object)> mergesOf(Enum row) => _merges[row] ?? const [];
}
