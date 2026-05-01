import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cubby/data/album_meta_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('returns null when no createdAt is stored', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesAlbumMetaStore(prefs);

    expect(await store.getCreatedAt('album-1'), isNull);
  });

  test('round-trips a DateTime via ISO 8601', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesAlbumMetaStore(prefs);
    final createdAt = DateTime.utc(2026, 5, 1, 12, 30);

    await store.setCreatedAt('album-1', createdAt);

    expect(await store.getCreatedAt('album-1'), createdAt);
  });

  test('keeps entries for different albums isolated', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesAlbumMetaStore(prefs);
    final a = DateTime.utc(2026, 1, 1);
    final b = DateTime.utc(2026, 6, 1);

    await store.setCreatedAt('album-a', a);
    await store.setCreatedAt('album-b', b);

    expect(await store.getCreatedAt('album-a'), a);
    expect(await store.getCreatedAt('album-b'), b);
  });

  test('remove deletes the stored value', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPreferencesAlbumMetaStore(prefs);
    await store.setCreatedAt('album-1', DateTime.utc(2026, 5, 1));

    await store.remove('album-1');

    expect(await store.getCreatedAt('album-1'), isNull);
  });
}
