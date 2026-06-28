import 'package:canon_codec/canon_codec.dart';
import 'link_spec.dart';
import 'screen_node.dart' show TreeNode;

/// Authoring DSL: a runtime-built tree the matcher walks and the generator
/// reads (via AST). Positional by construction — the same literal can sit at
/// many positions with different types.
///
/// Query/fragment terms are self-contained values: a bare key is a flag,
/// `Key(codec)` a value/list, `allOf`/`oneOf` group them (record / sealed
/// union), nestable. A group is just a value, so it can be stored as a reusable
/// `static` on the key enum and wired into the tree.

/// Anything placeable in a children set: a seg (static), a `slot`/`slots`
/// (dynamic), or a chained builder. `null` marks "this node also resolves with
/// no params" (the `Set<Seg?>` endpoint marker).
// `implements TreeNode<Never>`: a bare `slots`/`slot`/`seg` can sit directly in a
// screen's children (the widget form), and covariance makes it a valid child of
// any screen. The nav engine skips link nodes; only the matcher reads them.
abstract interface class LinkTreeNode implements TreeNode<Never> {
  Edge _toEdge(List<Term> shared);
}

/// A query/fragment term — a key (flag or value/list) or an `allOf`/`oneOf`
/// group.
abstract interface class QueryTerm {
  Term _buildTerm();
}

String _kebab(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');

List<Term> _terms(Set<QueryTerm> set) => [for (final t in set) t._buildTerm()];

LinkNode _assemble({
  String? name,
  required Set<LinkTreeNode?> children,
  required List<Term> ownQuery,
  required List<Term> ownFragment,
  required List<Term> sharedQuery,
  required List<Term> shared, // accumulated `.sharedQuery` from ancestors
}) {
  // `.sharedQuery` cascades to this node AND its descendants. Fragments don't
  // cascade — a fragment is terminal (one `#…` per URL), so it's own-node only.
  final childShared = [...shared, ...sharedQuery];
  final statics = <StaticEdge>[];
  SlotEdge? slot;
  var endpoint = false;
  for (final child in children) {
    if (child == null) {
      endpoint = true;
      continue;
    }
    final edge = child._toEdge(childShared);
    if (edge is StaticEdge) {
      statics.add(edge);
    } else {
      if (slot != null) {
        throw StateError('a children set may hold at most one slot');
      }
      slot = edge as SlotEdge;
    }
  }
  final query = [...ownQuery, ...shared, ...sharedQuery];
  return LinkNode(
    name: name,
    statics: statics,
    slot: slot,
    endpoint: endpoint,
    query: query.isEmpty ? null : ParamSchema(query),
    fragment: ownFragment.isEmpty ? null : ParamSchema(ownFragment),
  );
}

/// Path literals. The literal derives from the enum name (camelCase → kebab).
mixin SegBase on Enum implements LinkTreeNode {
  String get literal => _kebab(name);

  SegBuilder call([Set<LinkTreeNode?> children = const {}]) =>
      SegBuilder._(literal, name)..children = children;

  SegBuilder query(Set<QueryTerm> terms) =>
      SegBuilder._(literal, name).._ownQuery = _terms(terms);

  SegBuilder fragment(Set<QueryTerm> terms) =>
      SegBuilder._(literal, name).._ownFragment = _terms(terms);

  @override
  Edge _toEdge(List<Term> shared) => StaticEdge(
        literal,
        _assemble(
          name: name,
          children: const {},
          ownQuery: const [],
          ownFragment: const [],
          sharedQuery: const [],
          shared: shared,
        ),
      );
}

/// Shared chaining state for a static seg or a slot.
mixin _Chain implements LinkTreeNode {
  Set<LinkTreeNode?> children = const {};
  List<Term> _ownQuery = const [];
  List<Term> _ownFragment = const [];
  List<Term> _sharedQuery = const [];

  LinkNode _node(String? name, List<Term> shared) => _assemble(
        name: name,
        children: children,
        ownQuery: _ownQuery,
        ownFragment: _ownFragment,
        sharedQuery: _sharedQuery,
        shared: shared,
      );
}

final class SegBuilder with _Chain {
  SegBuilder._(this._literal, this._name);

  /// A link branch rooted at a screen (the `ScreenNodeBase.links(...)` boundary):
  /// literal is the screen name kebab-cased, exactly like a [SegBase].
  SegBuilder.forScreen(String name) : this._(_kebab(name), name);

  final String _literal;
  final String _name;

  SegBuilder call(Set<LinkTreeNode?> children) => this..children = children;
  SegBuilder query(Set<QueryTerm> t) => this.._ownQuery = _terms(t);
  SegBuilder fragment(Set<QueryTerm> t) => this.._ownFragment = _terms(t);
  SegBuilder sharedQuery(Set<QueryTerm> t) => this.._sharedQuery = _terms(t);

  @override
  Edge _toEdge(List<Term> shared) => StaticEdge(_literal, _node(_name, shared));
}

final class SlotBuilder with _Chain {
  SlotBuilder._(this.codecs);
  final List<Codec<Object?>> codecs;

  SlotBuilder call(Set<LinkTreeNode?> children) => this..children = children;
  SlotBuilder query(Set<QueryTerm> t) => this.._ownQuery = _terms(t);
  SlotBuilder fragment(Set<QueryTerm> t) => this.._ownFragment = _terms(t);
  SlotBuilder sharedQuery(Set<QueryTerm> t) => this.._sharedQuery = _terms(t);

  /// The widget form: a copy with [id] inserted as the FIRST union branch (the
  /// screen's own id is its canonical, renderable WidgetLink form; the declared
  /// `slots` are widgetless resolver alternatives that follow). Matches the
  /// generated branch indices: `[id, …declared]`.
  SlotBuilder withIdBranch(Codec<Object?> id) {
    final reordered = [id, ...codecs];
    return SlotBuilder._(reordered)
      ..children = children
      .._ownQuery = _ownQuery
      .._ownFragment = _ownFragment
      .._sharedQuery = _sharedQuery;
  }

  @override
  Edge _toEdge(List<Term> shared) => SlotEdge(codecs, _node(null, shared));
}

/// A single-codec slot: the next path segment is one value of [codec].
SlotBuilder slot(Codec<Object?> codec) => SlotBuilder._([codec]);

/// A union slot: the next segment is tried against [codecs] in set order
/// (first match wins). Generates a sealed type at the use-site.
SlotBuilder slots(Set<Codec<Object?>> codecs) => SlotBuilder._([...codecs]);

/// Query/fragment key names — enum values mixing this in. A bare value is a
/// flag; `Key(codec)` is a value/list.
mixin QueryKeyBase on Enum implements QueryTerm {
  QueryTerm call(Codec<Object?> codec) => _KeyValue(name, codec);

  @override
  Term _buildTerm() => KeyDef(name); // bare = flag
}

final class _KeyValue implements QueryTerm {
  _KeyValue(this.name, this.codec);
  final String name;
  final Codec<Object?> codec;

  @override
  Term _buildTerm() => codec is ListCodec
      ? KeyDef(name, codec: (codec as ListCodec).element, list: true)
      : KeyDef(name, codec: codec);
}

final class _Combinator implements QueryTerm {
  _Combinator(this.members, {required this.exclusive, this.mandatory = false});
  final Set<QueryTerm> members;
  final bool exclusive;
  final bool mandatory;

  @override
  Term _buildTerm() {
    final terms = [for (final m in members) m._buildTerm()];
    return exclusive
        ? OneOf(terms, mandatory: mandatory)
        : AllOf(terms, mandatory: mandatory);
  }
}

/// Flattens a query/fragment term set into a key→codec schema (codec null = a
/// flag). View-state placements (`screen(...).query({...})`) use this so the
/// engine can encode/decode the stored values against the URL.
Map<String, Codec<Object?>?> viewSchema(Set<QueryTerm> terms) {
  final out = <String, Codec<Object?>?>{};
  void add(Term t) {
    switch (t) {
      case KeyDef():
        out[t.name] = t.codec;
      case AllOf():
        t.members.forEach(add);
      case OneOf():
        t.members.forEach(add);
    }
  }

  for (final term in terms) {
    add(term._buildTerm());
  }
  return out;
}

/// Co-occurrence: all of [members] present together (→ record) or none.
QueryTerm allOf(Set<QueryTerm> members) => _Combinator(members, exclusive: false);

/// Mutual exclusion: exactly one of [members] present (→ sealed union) or none.
QueryTerm oneOf(Set<QueryTerm> members) => _Combinator(members, exclusive: true);

/// Like [allOf] but REQUIRED: the link only matches when all members are
/// present — a URL missing them is rejected, not resolved with a null group.
/// Link branches (`.link`/`slots`) only; rejected on screen view-state, where a
/// query is decoration, not part of the route's identity.
QueryTerm requireAllOf(Set<QueryTerm> members) =>
    _Combinator(members, exclusive: false, mandatory: true);

/// Like [oneOf] but REQUIRED: the link only matches when exactly one member is
/// present — a URL with none is rejected. Link branches only (see [requireAllOf]).
QueryTerm requireOneOf(Set<QueryTerm> members) =>
    _Combinator(members, exclusive: true, mandatory: true);

/// A domain root — a URL prefix (scheme + optional host). The first domain in
/// the tree is the one used for output. Inlined (not an enum): root-only by type.
final class Domain {
  Domain(this.url);
  final String url;

  DomainPlacement call(Set<LinkTreeNode?> children) =>
      DomainPlacement._(this, children);
}

final class DomainPlacement {
  DomainPlacement._(this.domain, this.children);
  final Domain domain;
  final Set<LinkTreeNode?> children;
}

/// Builds the whole link spec from a set of domain placements.
LinkSpec tree(Set<DomainPlacement> domains) => LinkSpec([
      for (final d in domains)
        DomainNode(
          d.domain.url,
          _assemble(
            children: d.children,
            ownQuery: const [],
            ownFragment: const [],
            sharedQuery: const [],
            shared: const [],
          ),
        ),
    ]);

/// Builds a root [LinkNode] from the `.links` branches gathered off the
/// `@screens` graph (each a screen-rooted `SegBuilder`) — the runtime link tree
/// the matcher walks. Domain-agnostic: the caller wraps it in a [DomainNode]
/// built from the URL's own origin at parse time.
LinkNode linkRoot(Set<LinkTreeNode?> branches) => _assemble(
      children: branches,
      ownQuery: const [],
      ownFragment: const [],
      sharedQuery: const [],
      shared: const [],
    );
