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
