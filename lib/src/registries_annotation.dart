/// Marks the library-private spec enum the registries generator reads. Each row
/// holds a (consumer-owned) registry/connection object plus the `@ids` node it is
/// keyed by; the generator emits the typed data surface and wires it to a ledger.
class Registries {
  const Registries();
}

/// The arg-less default.
const registries = Registries();

/// The contract the `@registries` enum wears. Ties this registries spec to an
/// identity space [Ids]: every row binds an [Ids] node as its [key]. Canon-side
/// only — it never references the (roots) registry it holds, so canon stays
/// decoupled from the data engine; the generator reads the held object's type.
mixin RegistryNode<Self extends RegistryNode<Self, Ids>, Ids> on Enum {
  Ids get key;
}
