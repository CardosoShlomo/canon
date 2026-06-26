import 'package:flutter/material.dart';
import 'package:canon/canon.dart';
import 'package:test/test.dart';

// The single navigation resolver: every external (blob-absent) URL — cold-start
// web URL or mobile deep-link — is handed to it via setNewRoutePath. A launch
// URL that lands before the resolver is registered replays exactly once.
enum R with ScreenNode<R> {
  home,
  feed;

  @override
  Widget get widget => const SizedBox.shrink();
}

NavGraph _boot() => NavGraph(
      {R.home(), R.feed()},
      initial: const SizedBox.shrink(),
      pageOf: (w, c, k) => MaterialPage(child: w),
    );

RouteInformation _link(String url) => RouteInformation(uri: Uri.parse(url));

void main() {
  test('resolver fires for an external (blob-absent) URL', () {
    final graph = _boot();
    final fired = <String>[];
    graph.setResolver(fired.add);
    graph.delegate.setNewRoutePath(_link('/feed'));
    expect(fired, ['/feed']);
  });

  test('a launch URL arriving before the resolver replays once on register', () {
    final graph = _boot();
    final fired = <String>[];
    graph.delegate.setNewRoutePath(_link('/feed')); // no resolver yet → stashed
    expect(fired, isEmpty);
    graph.setResolver(fired.add); // pending replays
    expect(fired, ['/feed']);
  });

  test('reassigning the resolver N times never re-fires the launch URL', () {
    final graph = _boot();
    final fired = <String>[];
    graph.delegate.setNewRoutePath(_link('/feed'));
    for (var i = 0; i < 100; i++) {
      graph.setResolver(fired.add);
    }
    expect(fired, ['/feed']); // consumed exactly once
  });

  test('a blob-present URL restores — never reaches the resolver', () {
    final graph = _boot();
    final fired = <String>[];
    graph.setResolver(fired.add);
    graph.delegate.setNewRoutePath(
      RouteInformation(uri: Uri.parse('/feed'), state: const <String, Object?>{}),
    );
    expect(fired, isEmpty);
  });
}
