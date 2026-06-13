import 'package:flutter/material.dart';
import 'package:canon/canon.dart';

part 'nav.nav.dart';

// The whole navigation space is ONE Set literal on a private enum. The
// generator turns it into a typed surface where illegal navigation is a
// compile error (you can only `go` to a screen's real children, only `pop`
// to a real ancestor).
@screens
enum _Screens with ScreenNode<Object?, _Screens> {
  splash(_Page('Splash')),
  signIn(_Page('Sign in')),
  home(_Page('Home')),
  feed(_Page('Feed')),
  profile(_Page('Profile')),
  item(_Page('Item'), String), // a detail screen keyed by an id
  settings(_Page('Settings')),
  about(_Page('About'));

  const _Screens(this.widget, [this.id]);
  final Widget widget;
  final Type? id;

  static final graph = NavGraph<_Screens>(
    {
      splash,
      signIn,
      // `.keep` preserves a tab's stack when you switch away and back.
      home.keep({item, settings({about})}),
      feed.keep({item}), // `item` lives under two tabs → placement narrowing
      profile.keep({settings({about})}),
    },
    initial: splash,
    pageOf: (screen, ctx, key) => MaterialPage(
      key: key,
      child: ScreenScope(entry: ctx.entry, child: screen.widget),
    ),
  );
}

class _Page extends StatelessWidget {
  const _Page(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Typed navigation — these calls only compile because the grammar
            // declares the targets.
            ElevatedButton(
              onPressed: () => Screen.goItem('42'),
              child: const Text('Open item 42'),
            ),
            ElevatedButton(
              onPressed: () => Screen.goFeed(),
              child: const Text('Feed tab'),
            ),
            ElevatedButton(
              onPressed: Screen.maybePop,
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
