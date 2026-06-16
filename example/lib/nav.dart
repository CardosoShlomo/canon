import 'package:flutter/material.dart';
import 'package:canon/canon.dart';

part 'nav.nav.dart';

// The whole navigation space is ONE Set literal on a private enum. The
// generator turns it into a typed surface where illegal navigation is a
// compile error (you can only `go` to a screen's real children, only `pop`
// to a real ancestor).
@screens
enum _Screens with ScreenNode<_Screens> {
  splash(_Page('Splash')),
  signIn(_Page('Sign in')),
  home(_Page('Home')),
  feed(_Page('Feed')),
  profile(_Page('Profile')),
  item(_Page('Item'), String), // a detail screen keyed by an id
  editItem(_Page('Edit item'), String), // its id IS item's (see .inherit below)
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
      // `.inherit(item)` makes editItem's id structurally item's: its push verb
      // takes no id (`goEditItem()`), reading the live item id instead.
      home.keep({item({editItem.inherit(item)}), settings({about})}),
      feed.keep({item({editItem.inherit(item)})}), // item lives under two tabs
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
            // `goFeed` is a kick-start (single-placement). `item` lives under
            // two tabs (a union), so it has no global verb — you chain to it
            // off a kick-start handle, which picks the placement.
            ElevatedButton(
              onPressed: () => Screen.goHome().goItem('42'),
              child: const Text('Open item 42 (in Home)'),
            ),
            // Zero-arg kick-start verbs are tear-offs — no closure, no context,
            // no string path: `onPressed: Screen.goFeed`.
            ElevatedButton(
              onPressed: Screen.goFeed,
              child: const Text('Feed tab'),
            ),
            // Back is the typed global pop (also a tear-off), shown only when
            // there's somewhere to pop (null at a root).
            if (Screen.canPop != null)
              ElevatedButton(
                onPressed: Screen.pop,
                child: const Text('Back'),
              ),
          ],
        ),
      ),
    );
  }
}
