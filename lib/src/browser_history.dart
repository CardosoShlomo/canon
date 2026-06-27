/// Web-only access to the browser History API, behind a conditional import so
/// VM/mobile builds (and `dart test`) compile against the no-op stub.
///
/// canon uses this for true back/forward semantics on the web: `Screen.pop()`
/// becomes `history.go(-1)` (consume the entry, don't push a parent duplicate),
/// and a cold-start deep link fans its stack out into real history entries.
library;

export 'browser_history_stub.dart'
    if (dart.library.js_interop) 'browser_history_web.dart';
