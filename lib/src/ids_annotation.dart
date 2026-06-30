import 'package:canon_codec/canon_codec.dart';

/// Marks the HAND-WRITTEN spec enum that is the app's id-space. Each row is an
/// identity (atomic, composite, or a plain value-codec passthrough) carrying its
/// [Codec] — how its key serialises in a URL. Nothing here is generated: the
/// enum IS the holder. `@screens`/`@registries` rows reference these rows by
/// dot-shorthand (`id: .user`), and canon reads `row.codec` to encode/decode.
///
/// The marker only LOCATES the id-space for the other generators (so a screen's
/// `id` or a registry's key can be validated against it) — it emits no code.
///
/// Applied as `@IDs()`. NOTE: there is deliberately no lowercase `const ids` —
/// the natural name a user gives their id-space enum is `Ids`, and the generated
/// nav code uses `ids` pervasively as an identifier, so a top-level `ids`/`Ids`
/// from canon would shadow them. `IDs` (capital D) avoids both.
class IDs {
  const IDs();
}

/// The contract an `@ids` enum wears: every row carries a [codec]. The node IS a
/// [Codec] (it delegates to its inner one), so a screen can bind it straight into
/// the existing `Codec? id` field (`id: .user`) and a registry can key by it —
/// the SAME node across both grammar trees. Generators read `node.codec` to
/// recover the specific value type (the node itself erases to `Codec<Object?>`).
mixin IdNode on Enum implements Codec<Object?> {
  Codec get codec;

  @override
  Object? decode(String token) => codec.decode(token);

  @override
  String encode(Object? value) => codec.encode(value);
}
