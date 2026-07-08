export 'package:canon_codec/canon_codec.dart' hide ListCodec;
// ScreenScope is @internal (canon wraps pages with it; the generated extension
// calls its statics). Exported so generated code resolves it; hand use is linted.
// ignore: invalid_export_of_internal_element
export 'src/nav_graph.dart' hide Nav;
export 'src/screen_node.dart'
    hide GrammarNode, NavSpec, NavResolution, resolveGo, resolvePop;
export 'src/screens_annotation.dart';
export 'src/entity_node.dart';
export 'src/fragment_path.dart';

// canon is the facade for the runtime model: it re-exports the ledger engine
// (which carries identifiable) so a consumer imports `canon` and has location,
// state, and identity in one. `@registries`/`RegistryNode` come from here.
export 'package:regent/regent.dart';

// Link layer — duplicated from canon_link (intentional; canon_link may later
// collapse into canon). The DSL (slot/slots/query/fragment/tree/Domain) is
// authored in the tree; spec/matcher back the generated link code.
export 'src/link_dsl.dart';
export 'src/link_spec.dart';
export 'src/link_matcher.dart';
