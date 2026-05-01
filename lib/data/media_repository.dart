import 'dart:io' show File, Platform;
import 'dart:typed_data';

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

  /// Assets in [album], paged. Default photo_manager sort is createDateTime
  /// descending, which matches F4.
  Future<List<AssetEntity>> getAssets(
    AssetPathEntity album, {
    int page = 0,
    int pageSize = 80,
  });

  /// Save a captured image into [album].
  ///
  /// Android: the relativePath places the file under `Pictures/<albumName>/`,
  /// which materialises the album folder on first save.
  /// iOS: the new asset is added to the photo library, then linked into
  /// [album] via [Editor.copyAssetToPath] (PhotoKit soft-link).
  Future<AssetEntity> saveImage({
    required Uint8List bytes,
    required String filename,
    required AssetPathEntity album,
  });

  Future<AssetEntity> saveVideo({
    required File file,
    required String filename,
    required AssetPathEntity album,
  });

  /// Delete the given assets. Returns the IDs that were successfully deleted.
  /// Android 11+ and iOS show a system confirmation dialog automatically.
  Future<List<String>> deleteAssets(List<AssetEntity> assets);
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

  @override
  Future<List<AssetEntity>> getAssets(
    AssetPathEntity album, {
    int page = 0,
    int pageSize = 80,
  }) {
    return album.getAssetListPaged(page: page, size: pageSize);
  }

  @override
  Future<AssetEntity> saveImage({
    required Uint8List bytes,
    required String filename,
    required AssetPathEntity album,
  }) async {
    final asset = await PhotoManager.editor.saveImage(
      bytes,
      filename: filename,
      relativePath: await _relativePathFor(
        album,
        fallback: 'Pictures/${album.name}',
      ),
    );
    if (Platform.isIOS || Platform.isMacOS) {
      return PhotoManager.editor.copyAssetToPath(
        asset: asset,
        pathEntity: album,
      );
    }
    return asset;
  }

  @override
  Future<AssetEntity> saveVideo({
    required File file,
    required String filename,
    required AssetPathEntity album,
  }) async {
    final asset = await PhotoManager.editor.saveVideo(
      file,
      title: filename,
      relativePath: await _relativePathFor(
        album,
        fallback: 'Movies/${album.name}',
      ),
    );
    if (Platform.isIOS || Platform.isMacOS) {
      return PhotoManager.editor.copyAssetToPath(
        asset: asset,
        pathEntity: album,
      );
    }
    return asset;
  }

  // Use the album's existing bucket path on Android so we don't fork the
  // album into a duplicate bucket with the same display name. iOS ignores
  // relativePath entirely; the fallback only matters when the album hasn't
  // materialised yet (Android empty-album case).
  Future<String> _relativePathFor(
    AssetPathEntity album, {
    required String fallback,
  }) async {
    final existing = await album.relativePathAsync;
    if (existing != null && existing.isNotEmpty) return existing;
    return fallback;
  }

  @override
  Future<List<String>> deleteAssets(List<AssetEntity> assets) {
    final ids = assets.map((a) => a.id).toList();
    return PhotoManager.editor.deleteWithIds(ids);
  }
}
