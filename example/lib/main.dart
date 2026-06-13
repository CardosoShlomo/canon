import 'package:flutter/material.dart';

import 'nav.dart';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    // Wire canon's delegate into a router app — that's the entire integration.
    return MaterialApp.router(routerDelegate: Screen.delegate);
  }
}
