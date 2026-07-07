import 'package:canon_codec/canon_codec.dart';

/// One position of a PATH-scheme fragment: a codec (open domain = a slug,
/// a [Codec.literal] singleton = a fixed segment) and the positions that may
/// follow it. Compose with `/`: `.product / {thumb, gallery / {imageIndex}}`.
///
/// The tree renders as `#<seg>[/<seg>]*` — no leading slash (the bare first
/// segment IS the classic HTML anchor). Decode is strict and total: any
/// mismatched position rejects the WHOLE fragment (no fragment, no crash).
class FragmentNode {
  const FragmentNode(this.codec, [this.children = const {}]);

  final Codec<Object?> codec;
  final Set<FragmentNode> children;
}

/// `/` composes a codec with what may follow it. The right side is a single
/// codec, a [FragmentNode], or a SET of either (a branch point).
extension FragmentPathComposition on Codec<Object?> {
  FragmentNode operator /(Object next) => FragmentNode(this, _nodes(next));
}

/// Branching off an already-composed node: `a / {b} / {c}` reads left to
/// right, so deeper composition nests on the right side instead — this
/// extension lets a set element itself be `gallery / {...}`.
Set<FragmentNode> _nodes(Object next) => switch (next) {
      FragmentNode n => {n},
      Codec<Object?> c => {FragmentNode(c)},
      Set<Object> s => {
          for (final e in s)
            switch (e) {
              FragmentNode n => n,
              Codec<Object?> c => FragmentNode(c),
              _ => throw ArgumentError(
                  'a fragment path position must be a Codec or a composed '
                  'node — got ${e.runtimeType}'),
            },
        },
      _ => throw ArgumentError(
          'the right side of / must be a Codec, a node, or a set of them'),
    };

/// Normalize a `path(...)` argument — a bare codec, one node, or a root
/// BRANCH SET (alternative first segments: `{deals, .product / {...}}`).
Set<FragmentNode> fragmentRoots(Object tree) => _nodes(tree);

/// Decode a raw fragment string against [roots]. Returns the decoded
/// positions in order, or null if any position rejects (strict). Tolerates
/// (strips) a `:~:` directive tail — that's user-agent territory.
List<Object?>? decodeFragmentPath(Set<FragmentNode> roots, String raw) {
  var s = raw;
  final directive = s.indexOf(':~:');
  if (directive != -1) s = s.substring(0, directive);
  if (s.isEmpty) return null;
  if (s.startsWith('/')) return null; // no leading slash — not an alias form
  final segments = s.split('/');
  final values = <Object?>[];
  var level = roots;
  for (final seg in segments) {
    final token = Uri.decodeComponent(seg);
    FragmentNode? matched;
    Object? value;
    for (final n in level) {
      final v = n.codec.decode(token);
      if (v != null) {
        matched = n;
        value = v;
        break;
      }
    }
    if (matched == null) return null;
    values.add(value);
    level = matched.children;
  }
  return values;
}

/// Encode decoded positions back to the raw fragment string, walking the
/// same tree. Returns null if the values don't fit the tree (a write of an
/// illegal path). Percent-encodes embedded '/' — the splitter owns it.
String? encodeFragmentPath(Set<FragmentNode> roots, List<Object?> values) {
  if (values.isEmpty) return null;
  final parts = <String>[];
  var level = roots;
  for (final v in values) {
    FragmentNode? matched;
    String? token;
    for (final n in level) {
      final t = _tryEncode(n.codec, v);
      // round-trip check: the codec must own this value
      if (t != null && n.codec.decode(t) != null) {
        matched = n;
        token = t;
        break;
      }
    }
    if (matched == null || token == null) return null;
    parts.add(Uri.encodeComponent(token).replaceAll('%2C', ','));
    level = matched.children;
  }
  return parts.join('/');
}

String? _tryEncode(Codec<Object?> codec, Object? value) {
  try {
    return codec.encode(value);
  } catch (_) {
    return null;
  }
}
