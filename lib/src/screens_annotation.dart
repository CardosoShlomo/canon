/// Marks the library-private spec enum the nav generator reads.
/// Rows: identifier = screen name, first positional = const widget,
/// optional second positional = id Type (named types only).
class Screens {
  const Screens({this.domain});

  /// The app's canonical domain (e.g. `'https://allinloop.com'`), baked as the
  /// default for the generated `toUri(link, [domain])`. Output-only: `parseLink`
  /// stays host-agnostic and instead *reports* the URL's origin. A const string
  /// (literal or `const` ref); null when the app emits no shareable URLs.
  final String? domain;
}

/// The arg-less default; use `@Screens(domain: '…')` to declare a link domain.
const screens = Screens();

/// THE spec mark: one annotation for every canon spec enum — ids, entities,
/// regents, screens, link trees. The row MIXIN is the source of truth
/// ([IdNode], entity rows, `RegentNode`, [ScreenNode], [LinkNode]); the
/// generator dispatches on it, so the mark only says "generate here".
/// The main screens enum is the one that declares the [NavGraph]; a link
/// domain is declared IN the tree (`Domain('https://…')`), not here.
class Canon {
  const Canon();
}

/// The spec mark — `@canon enum _Screens with ScreenNode<_Screens> {…}`.
const canon = Canon();
