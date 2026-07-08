import 'package:canon_codec/canon_codec.dart';

/// The runtime link spec the matcher walks. The authoring DSL (Domain/Seg/slot)
/// builds this; the generator reads the SAME source via AST to emit the typed
/// `Link` surface. Plain data — no Flutter, no nav.

/// A node in a query/fragment schema: a single key, or a typed combinator.
sealed class Term {
  const Term();
}

/// One key. [codec] null = a flag (presence only); [list] true = repeated key
/// carrying an ordered `List<elem>` ([codec] is then the ELEMENT codec).
final class KeyDef extends Term {
  const KeyDef(this.name, {this.codec, this.list = false, this.mandatory = true});

  final String name;
  final Codec<Object?>? codec;
  final bool list;
  final bool mandatory;
}

/// Co-occurrence: all members present (→ record) or all absent. A partial set
/// is a parse failure. [mandatory] true forbids the all-absent case too — the
/// link only matches when every member is present (link branches only).
final class AllOf extends Term {
  const AllOf(this.members, {this.mandatory = false});
  final List<Term> members;
  final bool mandatory;
}

/// Mutual exclusion: exactly one member present (→ sealed union), or none. Two
/// or more present is a parse failure. [mandatory] true forbids the none case —
/// the link only matches when exactly one member is present (link branches only).
final class OneOf extends Term {
  const OneOf(this.members, {this.mandatory = false});
  final List<Term> members;
  final bool mandatory;
}

/// A query (or fragment) schema: a list of terms. Unmodeled keys are always
/// ignored — what isn't in the schema isn't data. Capture arbitrary query by
/// modeling an explicit raw key.
final class ParamSchema {
  const ParamSchema(this.terms);

  final List<Term> terms;

  static const empty = ParamSchema([]);
}

/// A path edge: a static literal, or a slot trying [codecs] in precedence order.
sealed class Edge {
  const Edge(this.child);
  final PathNode child;
}

final class StaticEdge extends Edge {
  const StaticEdge(this.literal, super.child);
  final String literal;
}

final class SlotEdge extends Edge {
  const SlotEdge(this.codecs, super.child);
  final List<Codec<Object?>> codecs;
}

/// One path position. Statics are tried before the (at most one) slot.
/// A node resolves (is an endpoint) when [endpoint] is set, when it has a query
/// or fragment schema (params imply resolution), or when it is a leaf.
final class PathNode {
  PathNode({
    this.name,
    this.statics = const [],
    this.slot,
    this.endpoint = false,
    this.query,
    this.fragment,
  });

  final String? name;
  final List<StaticEdge> statics;
  final SlotEdge? slot;
  final bool endpoint;
  final ParamSchema? query;
  final ParamSchema? fragment;

  bool get resolves =>
      endpoint || query != null || fragment != null || _isLeaf;
  bool get _isLeaf => statics.isEmpty && slot == null;
}

/// A domain root: a URL prefix (scheme + optional host + optional base path) and
/// its subtree. The prefix is parsed once into components the matcher compares
/// structurally (not by string prefix), so `example.com` never matches
/// `example.com.evil.com`.
final class DomainNode {
  DomainNode(this.prefix, this.root) : _uri = Uri.parse(prefix);

  final String prefix;
  final PathNode root;
  final Uri _uri;

  String get scheme => _uri.scheme.toLowerCase();
  String get host => _uri.host.toLowerCase();

  /// Port with http/https defaults filled in, so `:443`/implicit https match.
  int get port {
    if (_uri.hasPort) return _uri.port;
    return switch (scheme) { 'http' => 80, 'https' => 443, _ => 0 };
  }

  /// The base path segments the URL must start with (e.g. `/app` → `[app]`).
  List<String> get basePath =>
      [for (final s in _uri.pathSegments) if (s.isNotEmpty) s];
}

final class LinkSpec {
  const LinkSpec(this.domains);
  final List<DomainNode> domains;
}
