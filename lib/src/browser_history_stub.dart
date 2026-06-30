/// No-op History API for non-web platforms. On mobile canon owns the back-stack
/// directly, so none of this is reachable (all calls are `kIsWeb`-gated).
bool get isBrowser => false;

Future<void> enableMultiEntryHistory() async {}
void usePathUrls() {}

String currentPath() => '/';
void historyGo(int delta) {}
int historyLength() => 0;
void historyPush(String url, Object? state) {}
void historyReplace(String url, Object? state) {}
Object? currentHistoryState() => null;
void onPopState(void Function(Object? state, String url) handler) {}
