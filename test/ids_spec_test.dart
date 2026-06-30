import 'package:canon/canon.dart';
import 'package:test/test.dart';

// A hand-written @ids enum: the id-space IS this enum. Named identities,
// a composite, and value-codec passthroughs are all just rows. No generation.
@ids
enum Ids with IdNode {
  user(.uuid),
  ad(.uuid),
  adChat(Record2Codec(.uuid, .uuid)), // composite identity (ad, user)
  string(.string),
  integer(.integer);

  const Ids(this.codec);
  @override
  final Codec codec;
}

// A screens-shaped enum referencing the id-space by dot-shorthand — the spec
// points at a spec type (Ids), never anything generated.
enum Screen {
  profile(id: .user),
  adChatScreen(id: .adChat),
  search(id: .string);

  const Screen({required this.id});
  final Ids id;
}

void main() {
  test('screen rows dot-shorthand into the @ids enum', () {
    expect(Screen.profile.id, Ids.user);
    expect(Screen.adChatScreen.id, Ids.adChat);
    expect(Screen.search.id, Ids.string);
  });

  const uuidA = '11111111-1111-1111-1111-111111111111';
  const uuidB = '22222222-2222-2222-2222-222222222222';

  test('each id-node carries a codec that round-trips its key', () {
    expect(Ids.user.codec.encode(uuidA), uuidA);
    expect(Ids.user.codec.decode(uuidA), uuidA);
    expect(Ids.integer.codec.encode(7), '7');
    expect(Ids.integer.codec.decode('7'), 7);
  });

  test('a composite id-node serialises the record key', () {
    final codec = Ids.adChat.codec;
    final encoded = codec.encode((uuidA, uuidB));
    expect(codec.decode(encoded), (uuidA, uuidB));
  });
}
