import 'package:canon_codec/canon_codec.dart';
import 'link_spec.dart';

/// One consumed path step — kept so a match can print itself back.
sealed class _Hit {
  const _Hit();
}

final class _StaticHit extends _Hit {
  const _StaticHit(this.literal);
  final String literal;
}

final class _SlotHit extends _Hit {
  const _SlotHit(this.value, this.codec);
  final Object? value;
  final Codec<Object?> codec;
}

/// A successful parse. [path] is the ordered dynamic slot values (statics are
/// structural, omitted); [query]/[fragment] are decoded params by key name.
/// Unmodeled query keys are ignored, never captured.
final class LinkMatch {
  LinkMatch._(this._domain, this._hits, this.node, this.path, this.branches,
      this.query, this.fragment);

  final DomainNode _domain;
  final List<_Hit> _hits;
  final LinkNode node;
  final List<Object?> path;

  /// Per slot value (in [path] order), the index of the codec that matched —
  /// the union branch the generated sealed capture type switches on.
  final List<int> branches;
  final Map<String, Object?> query;
  final Map<String, Object?> fragment;

  String? get name => node.name;

  /// The route's structural key: static literals verbatim, each slot as `*`,
  /// joined by `/` (e.g. `user/*`). Uniquely identifies the resolving node —
  /// the discriminator the generated typed layer switches on.
  String get template =>
      _hits.map((h) => h is _StaticHit ? h.literal : '*').join('/');
}

/// Strict, bidirectional URL ↔ match codec over a [LinkSpec].
final class LinkMatcher {
  const LinkMatcher(this.spec);

  final LinkSpec spec;

  /// Parse a URL string into a match, or null for any unrecognized shape
  /// (unknown domain, no committed route, failed/missing params).
  LinkMatch? parse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    for (final domain in spec.domains) {
      final segments = _domainSegments(domain, uri);
      if (segments == null) continue;
      final m = _parseIn(domain, uri, segments);
      if (m != null) return m;
    }
    return null;
  }

  /// The path segments under [domain] (after its base path), or null if [uri]
  /// isn't under this domain. Compares scheme/host/port structurally — no string
  /// prefixing (so `example.com` ≠ `example.com.evil.com` ≠ `example.community`).
  List<String>? _domainSegments(DomainNode domain, Uri uri) {
    if (uri.scheme.toLowerCase() != domain.scheme) return null;
    if (uri.host.toLowerCase() != domain.host) return null;
    final port = uri.hasPort
        ? uri.port
        : switch (uri.scheme.toLowerCase()) { 'http' => 80, 'https' => 443, _ => 0 };
    if (port != domain.port) return null;
    final segs = [for (final s in uri.pathSegments) if (s.isNotEmpty) s];
    final base = domain.basePath;
    if (segs.length < base.length) return null;
    for (var i = 0; i < base.length; i++) {
      if (segs[i] != base[i]) return null;
    }
    return segs.sublist(base.length);
  }

  LinkMatch? _parseIn(DomainNode domain, Uri uri, List<String> segments) {
    // Phase 1 — route-finding: committed fallthrough, no backtracking.
    var node = domain.root;
    final hits = <_Hit>[];
    final path = <Object?>[];
    final branches = <int>[];
    for (final token in segments) {
      final static = _firstStatic(node, token);
      if (static != null) {
        hits.add(_StaticHit(token));
        node = static.child;
        continue;
      }
      final slot = node.slot;
      if (slot == null) return null;
      Object? decoded;
      Codec<Object?>? hitCodec;
      var index = -1;
      for (var i = 0; i < slot.codecs.length; i++) {
        final v = slot.codecs[i].decode(token);
        if (v != null) {
          decoded = v;
          hitCodec = slot.codecs[i];
          index = i;
          break;
        }
      }
      if (hitCodec == null) return null;
      hits.add(_SlotHit(decoded, hitCodec));
      path.add(decoded);
      branches.add(index);
      node = slot.child;
    }
    if (!node.resolves) return null;

    // Phase 2 — params on the committed route. No fallthrough.
    final rawQuery = uri.queryParametersAll;
    final rawFrag = _splitAll(uri.fragment.isEmpty ? null : uri.fragment);
    final query = _decodeParams(node.query, rawQuery);
    if (query == null) return null;
    final fragment = _decodeParams(node.fragment, rawFrag);
    if (fragment == null) return null;

    return LinkMatch._(domain, hits, node, path, branches, query, fragment);
  }

  StaticEdge? _firstStatic(LinkNode node, String token) {
    for (final e in node.statics) {
      if (e.literal == token) return e;
    }
    return null;
  }

  /// Decodes one param schema against the raw repeated-key map. Returns null on
  /// any strict failure (bad value, missing required single, unknown key when
  /// the schema is closed).
  /// Decodes a param schema. Keys not in the schema are ignored. Returns null
  /// only on a strict failure (bad modeled value, combinator violation).
  Map<String, Object?>? _decodeParams(
      ParamSchema? schema, Map<String, List<String>> raw) {
    schema ??= ParamSchema.empty;
    final values = <String, Object?>{};
    for (final term in schema.terms) {
      if (!_decodeTerm(term, raw, values)) return null;
    }
    return values;
  }

  /// Decodes [term] into [values], enforcing combinator constraints. Returns
  /// false on any strict failure.
  bool _decodeTerm(Term term, Map<String, List<String>> raw,
      Map<String, Object?> values) {
    switch (term) {
      case KeyDef():
        final occ = raw[term.name];
        if (term.codec == null) {
          values[term.name] = occ != null; // flag
          return true;
        }
        if (term.list) {
          if (occ == null) {
            values[term.name] = const [];
            return true;
          }
          final out = [];
          for (final tok in occ) {
            final v = term.codec!.decode(tok);
            if (v == null) return false;
            out.add(v);
          }
          values[term.name] = out;
          return true;
        }
        if (occ == null) {
          if (term.required) return false;
          return true; // optional single absent — no entry
        }
        final v = term.codec!.decode(occ.first);
        if (v == null) return false;
        values[term.name] = v;
        return true;
      case AllOf(:final members):
        final present = members.where((t) => _present(t, raw)).toList();
        if (present.isEmpty) return true; // group absent
        if (present.length != members.length) return false; // partial
        for (final t in members) {
          if (!_decodeTerm(t, raw, values)) return false;
        }
        return true;
      case OneOf(:final members):
        final present = members.where((t) => _present(t, raw)).toList();
        if (present.isEmpty) return true; // group absent
        if (present.length > 1) return false; // mutual exclusion violated
        return _decodeTerm(present.first, raw, values);
    }
  }

  bool _present(Term term, Map<String, List<String>> raw) => switch (term) {
        KeyDef() => raw.containsKey(term.name),
        AllOf(:final members) => members.any((t) => _present(t, raw)),
        OneOf(:final members) => members.any((t) => _present(t, raw)),
      };

  /// Encodes a query value, leaving commas literal (a legal sub-delim) so a
  /// comma-joined codec prints `a,b,c` rather than `a%2Cb%2Cc`.
  static String _encodeValue(String s) =>
      Uri.encodeQueryComponent(s).replaceAll('%2C', ',');

  static Map<String, List<String>> _splitAll(String? q) {
    if (q == null || q.isEmpty) return const {};
    return Uri.parse('?$q').queryParametersAll;
  }

  /// Print a match back to its canonical URL string. Inverse of [parse] for any
  /// match this spec produced.
  String print(LinkMatch match) {
    final buf = StringBuffer(match._domain.prefix);
    for (final hit in match._hits) {
      buf.write('/');
      switch (hit) {
        case _StaticHit(:final literal):
          buf.write(Uri.encodeComponent(literal));
        case _SlotHit(:final value, :final codec):
          buf.write(Uri.encodeComponent(codec.encode(value)));
      }
    }
    final query = _printParams(match.node.query, match.query);
    if (query.isNotEmpty) buf.write('?$query');
    final frag = _printParams(match.node.fragment, match.fragment);
    if (frag.isNotEmpty) buf.write('#$frag');
    return buf.toString();
  }

  /// Prints a URL from a [template] (the structural key, e.g. `user/*`), the
  /// ordered slot [path] values, and the [query]/[fragment] value maps — the
  /// inverse used by the generated typed `toUri()`. Single-slot routes only
  /// (a union slot's variant can't be inferred from the value alone yet).
  String printRoute({
    required String template,
    List<Object?> path = const [],
    List<int> branches = const [],
    Map<String, Object?> query = const {},
    Map<String, Object?> fragment = const {},
  }) {
    final domain = spec.domains.first;
    final segments = template.isEmpty ? const <String>[] : template.split('/');
    final buf = StringBuffer(domain.prefix);
    var node = domain.root;
    var pi = 0;
    for (final seg in segments) {
      buf.write('/');
      if (seg == '*') {
        final codec = node.slot!.codecs[pi < branches.length ? branches[pi] : 0];
        buf.write(Uri.encodeComponent(_encChecked(codec, path[pi], 'path segment $pi')));
        pi++;
        node = node.slot!.child;
      } else {
        buf.write(Uri.encodeComponent(seg));
        node = node.statics.firstWhere((e) => e.literal == seg).child;
      }
    }
    final q = _printParams(node.query, query);
    if (q.isNotEmpty) buf.write('?$q');
    final f = _printParams(node.fragment, fragment);
    if (f.isNotEmpty) buf.write('#$f');
    return buf.toString();
  }

  /// Encodes [value] and verifies it decodes back (round-trips), so `toUri()`
  /// never emits a token its own parser would reject. A failure means a Link was
  /// built with a value this codec can't represent — a programmer error, thrown.
  String _encChecked(Codec codec, Object? value, String label) {
    final token = codec.encode(value);
    if (codec.decode(token) == null) {
      throw ArgumentError.value(value, label,
          'is not valid for its codec — toUri() would produce an unparseable URL');
    }
    return token;
  }

  String _printParams(ParamSchema? schema, Map<String, Object?> values) {
    if (schema == null) return '';
    final parts = <String>[];
    for (final term in schema.terms) {
      _printTerm(term, values, parts);
    }
    return parts.join('&');
  }

  void _printTerm(Term term, Map<String, Object?> values, List<String> parts) {
    switch (term) {
      case KeyDef():
        final v = values[term.name];
        if (term.codec == null) {
          if (v == true) parts.add(Uri.encodeQueryComponent(term.name));
          return;
        }
        if (term.list) {
          for (final e in (v as List? ?? const [])) {
            parts.add('${Uri.encodeQueryComponent(term.name)}'
                '=${_encodeValue(_encChecked(term.codec!, e, term.name))}');
          }
          return;
        }
        if (v == null) return;
        parts.add('${Uri.encodeQueryComponent(term.name)}'
            '=${_encodeValue(_encChecked(term.codec!, v, term.name))}');
      case AllOf(:final members):
      case OneOf(:final members):
        for (final t in members) {
          _printTerm(t, values, parts);
        }
    }
  }
}
