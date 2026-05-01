import 'dart:io' show Platform;

import 'package:photo_manager/photo_manager.dart';

abstract class MediaRepository {
  Future<PermissionState> requestPermission();

  Future<List<AssetPathEntity>> getUserAlbums();

  Future<AssetPathEntity?> findAlbumByName(String name);

  /// Returns the album with the given name, creating it if needed.
  ///
  /// On Android, an album cannot be created empty via MediaStore — the
  /// folder only materialises when the first asset is saved into
  /// `Pictures/[name]/` or `DCIM/[name]/`. If no matching album exists yet,
  /// this method returns `null`; the caller is expected to invoke
  /// `saveImage`/`saveVideo` with that relative path to bring it into
  /// existence.
  Future<AssetPathEntity?> createAlbum(String name);
}

class PhotoManagerMediaRepository implements MediaRepository {
  @override
  Future<PermissionState> requestPermission() {
    return PhotoManager.requestPermissionExtend();
  }

  @override
  Future<List<AssetPathEntity>> getUserAlbums() {
    return PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
      hasAll: false,
    );
  }

  @override
  Future<AssetPathEntity?> findAlbumByName(String name) async {
    final albums = await getUserAlbums();
    for (final album in albums) {
      if (album.name == name) return album;
    }
    return null;
  }

  @override
  Future<AssetPathEntity?> createAlbum(String name) async {
    final existing = await findAlbumByName(name);
    if (existing != null) return existing;

    if (Platform.isIOS || Platform.isMacOS) {
      return PhotoManager.editor.darwin.createAlbum(name);
    }
    return null;
  }
}
