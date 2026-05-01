import 'package:shared_preferences/shared_preferences.dart';

abstract class AlbumMetaStore {
  Future<DateTime?> getCreatedAt(String albumId);

  Future<void> setCreatedAt(String albumId, DateTime createdAt);

  Future<void> remove(String albumId);
}

class SharedPreferencesAlbumMetaStore implements AlbumMetaStore {
  SharedPreferencesAlbumMetaStore(this._prefs);

  static const _keyPrefix = 'album.createdAt.';

  final SharedPreferences _prefs;

  String _key(String albumId) => '$_keyPrefix$albumId';

  @override
  Future<DateTime?> getCreatedAt(String albumId) async {
    final raw = _prefs.getString(_key(albumId));
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  @override
  Future<void> setCreatedAt(String albumId, DateTime createdAt) {
    return _prefs.setString(_key(albumId), createdAt.toIso8601String());
  }

  @override
  Future<void> remove(String albumId) {
    return _prefs.remove(_key(albumId));
  }
}
