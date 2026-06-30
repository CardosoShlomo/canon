import 'dart:js_interop';

import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_web_plugins/url_strategy.dart' show usePathUrlStrategy;
import 'package:web/web.dart' as web;

/// Switch the engine to clean PATH urls (no `#`) — canon's default. Called once
/// before the Router reads the launch URL, so deep links round-trip as real paths.
void usePathUrls() => usePathUrlStrategy();

/// Put the Flutter engine in multi-entry history mode so browser back/forward
/// are real history navigations (the single-entry default cancels back). The
/// switch is async — callers await the returned future before reporting the
/// cold-start fan-out, else it lands while still single-entry and collapses.
Future<void> enableMultiEntryHistory() =>
    SystemNavigator.selectMultiEntryHistory();

/// Browser History API access (web build). canon owns the history directly here
/// — raw `pushState`/`replaceState`/`go` for output and its own `popstate`
/// listener for input — so the engine's coalescing history layer is out of the
/// loop and back/forward/pop behave exactly as canon commits them.
bool get isBrowser => true;

/// The current location as a path (`/a/b?x#y`), the cold-start / popstate URL.
String currentPath() {
  final l = web.window.location;
  return '${l.pathname}${l.search}${l.hash}';
}

/// Navigate history by [delta] (negative = back). Fires `popstate`.
void historyGo(int delta) => web.window.history.go(delta);

/// Total entries in the session history (diagnostic).
int historyLength() => web.window.history.length;

/// A genuine new entry carrying [state] (canon's blob) under [url].
void historyPush(String url, Object? state) =>
    web.window.history.pushState(state?.jsify(), '', url);

/// Overwrite the current entry with [url] + [state].
void historyReplace(String url, Object? state) =>
    web.window.history.replaceState(state?.jsify(), '', url);

/// The current entry's stored blob (e.g. on cold-boot/refresh), or null.
Object? currentHistoryState() => web.window.history.state?.dartify();

/// Held reference to the live JS callback — kept so it isn't garbage-collected
/// (which silently stops `popstate`) and so a hot restart can remove the prior
/// generation's listener before adding a new one (else stale listeners from
/// disposed graphs keep firing and throw).
web.EventListener? _popListener;

/// Register the single `popstate` handler — fired on browser back/forward with
/// the landed entry's stored blob + url. Idempotent across hot restart.
void onPopState(void Function(Object? state, String url) handler) {
  if (_popListener != null) {
    web.window.removeEventListener('popstate', _popListener);
  }
  _popListener = (web.Event e) {
    handler((e as web.PopStateEvent).state?.dartify(), currentPath());
  }.toJS;
  web.window.addEventListener('popstate', _popListener);
}
