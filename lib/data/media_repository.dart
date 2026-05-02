import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

/// Unified album type used by the UI. Hides the difference between an
/// album that exists in the system media store and an in-memory
/// placeholder created by the user that hasn't received its first asset
/// yet (Android cannot create empty MediaStore folders).
sealed class AlbumDisplay {
  String get name;
  int get assetCount;
}

class RealAlbum extends AlbumDisplay {
  RealAlbum({required this.source, required this.assetCount});

  final AssetPathEntity source;
  @override
  final int assetCount;

  @override
  String get name => source.name;
}

class PlaceholderAlbum extends AlbumDisplay {
  PlaceholderAlbum(this.name);

  @override
  final String name;
  @override
  int get assetCount => 0;
}

/// Thrown by [MediaRepository.createAlbum] when an album (real or
/// placeholder) with the same name already exists.
class DuplicateAlbumException implements Exception {
  DuplicateAlbumException(this.name);
  final String name;

  @override
  String toString() => 'DuplicateAlbumException: $name';
}

abstract class MediaRepository {
  Future<PermissionState> requestPermission();

  /// Present the iOS Limited Photos picker so the user can broaden the
  /// app's access to additional assets. No-op on Android.
  Future<void> presentLimitedPicker();

  /// User-facing album list: system albums + in-memory placeholders.
  /// Real albums take precedence if both share a name (shouldn't happen
  /// because [createAlbum] rejects duplicates, but defensive).
  Future<List<AlbumDisplay>> getUserAlbums();

  /// Create a new album with the given name.
  ///
  /// - iOS/macOS: creates an empty system album immediately.
  /// - Android: registers an in-memory [PlaceholderAlbum]. The actual
  ///   `Pictures/<name>/` folder materialises only when the first asset
  ///   is saved into it via [saveImage] or [saveVideo], which also
  ///   promotes the placeholder to a [RealAlbum] on the next list refresh.
  ///
  /// Throws [DuplicateAlbumException] if any album (real or placeholder)
  /// with the same name already exists.
  Future<AlbumDisplay> createAlbum(String name);

  /// Assets in [album], paged. Default photo_manager sort is createDateTime
  /// descending, which matches F4. Returns empty for placeholders.
  Future<List<AssetEntity>> getAssets(
    AlbumDisplay album, {
    int page = 0,
    int pageSize = 80,
  });

  /// Save a captured image into [album].
  ///
  /// If [album] is a [PlaceholderAlbum], the first save creates the
  /// underlying system folder (Android) and the placeholder is removed
  /// from the in-memory list.
  Future<AssetEntity> saveImage({
    required Uint8List bytes,
    required String filename,
    required AlbumDisplay album,
  });

  Future<AssetEntity> saveVideo({
    required File file,
    required String filename,
    required AlbumDisplay album,
  });

  /// Delete the given assets. Returns the IDs that were successfully deleted.
  /// Android 11+ and iOS show a system confirmation dialog automatically.
  Future<List<String>> deleteAssets(List<AssetEntity> assets);
}

class PhotoManagerMediaRepository implements MediaRepository {
  // Placeholder albums live only for the lifetime of the process. Losing
  // them on restart is intentional per the design call: an album the user
  // never put a photo into shouldn't persist.
  final List<String> _placeholderNames = [];

  @override
  Future<PermissionState> requestPermission() {
    return PhotoManager.requestPermissionExtend();
  }

  @override
  Future<void> presentLimitedPicker() async {
    // Supported on iOS 14+ (Limited Photos) and Android 14+
    // (READ_MEDIA_VISUAL_USER_SELECTED partial access). photo_manager
    // itself no-ops on other platforms, so no extra guard is needed here.
    await PhotoManager.presentLimited();
  }

  Future<List<AssetPathEntity>> _systemAlbums() {
    return PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
      hasAll: false,
      // iOS: exclude smart albums (Recents, Favorites, Screenshots, ...).
      // Android has no smart-album concept; this filter is iOS-only.
      pathFilterOption: const PMPathFilter(
        darwin: PMDarwinPathFilter(
          type: [PMDarwinAssetCollectionType.album],
        ),
      ),
    );
  }

  Future<AssetPathEntity?> _findSystemAlbumByName(String name) async {
    final albums = await _systemAlbums();
    for (final album in albums) {
      if (album.name == name) return album;
    }
    return null;
  }

  @override
  Future<List<AlbumDisplay>> getUserAlbums() async {
    final system = await _systemAlbums();
    final realAlbums = await Future.wait(
      system.map((e) async {
        final count = await e.assetCountAsync;
        return RealAlbum(source: e, assetCount: count);
      }),
    );
    // Drop placeholders whose name now exists as a real album. This
    // happens after a successful first-save promotes them, but is also
    // defensive against race conditions where the system album appeared
    // through other means (e.g. user created a folder via file manager).
    final realNames = realAlbums.map((a) => a.name).toSet();
    _placeholderNames.removeWhere(realNames.contains);
    final placeholderAlbums = _placeholderNames
        .map(PlaceholderAlbum.new)
        .toList();
    return [...realAlbums, ...placeholderAlbums];
  }

  @override
  Future<AlbumDisplay> createAlbum(String name) async {
    // Reject duplicates regardless of source (system album or another
    // placeholder). Per UX policy: the user should never silently land
    // in an existing album when they meant to create a new one.
    final existing = await _findSystemAlbumByName(name);
    if (existing != null) {
      throw DuplicateAlbumException(name);
    }
    if (_placeholderNames.contains(name)) {
      throw DuplicateAlbumException(name);
    }

    if (Platform.isIOS || Platform.isMacOS) {
      final created = await PhotoManager.editor.darwin.createAlbum(name);
      if (created == null) {
        // photo_manager docs say this can happen if the system rejects
        // the request; surface as duplicate so the UI can show the same
        // message rather than a cryptic null path.
        throw DuplicateAlbumException(name);
      }
      final count = await created.assetCountAsync;
      return RealAlbum(source: created, assetCount: count);
    }

    // Android: register placeholder, materialised on first asset save.
    _placeholderNames.add(name);
    return PlaceholderAlbum(name);
  }

  @override
  Future<List<AssetEntity>> getAssets(
    AlbumDisplay album, {
    int page = 0,
    int pageSize = 80,
  }) async {
    if (album is PlaceholderAlbum) return const [];
    final source = (album as RealAlbum).source;
    return source.getAssetListPaged(page: page, size: pageSize);
  }

  @override
  Future<AssetEntity> saveImage({
    required Uint8List bytes,
    required String filename,
    required AlbumDisplay album,
  }) async {
    final relativePath = await _resolveRelativePath(
      album,
      mediaRoot: 'Pictures',
    );
    final asset = await PhotoManager.editor.saveImage(
      bytes,
      filename: filename,
      relativePath: relativePath,
    );
    return _afterSave(asset: asset, album: album);
  }

  @override
  Future<AssetEntity> saveVideo({
    required File file,
    required String filename,
    required AlbumDisplay album,
  }) async {
    final relativePath = await _resolveRelativePath(
      album,
      mediaRoot: 'Movies',
    );
    final asset = await PhotoManager.editor.saveVideo(
      file,
      title: filename,
      relativePath: relativePath,
    );
    return _afterSave(asset: asset, album: album);
  }

  // For RealAlbum: reuse the existing bucket path on Android so we don't
  // fork the album into a duplicate bucket with the same display name.
  // For PlaceholderAlbum: there is no existing path yet; use the
  // mediaRoot/<name>/ convention to materialise the folder.
  // iOS ignores relativePath entirely.
  Future<String> _resolveRelativePath(
    AlbumDisplay album, {
    required String mediaRoot,
  }) async {
    if (album is RealAlbum) {
      final existing = await album.source.relativePathAsync;
      if (existing != null && existing.isNotEmpty) return existing;
      return '$mediaRoot/${album.name}';
    }
    return '$mediaRoot/${album.name}';
  }

  Future<AssetEntity> _afterSave({
    required AssetEntity asset,
    required AlbumDisplay album,
  }) async {
    if (album is PlaceholderAlbum) {
      // First save just materialised the system folder; remove the
      // placeholder so the next list refresh shows the real album.
      _placeholderNames.remove(album.name);
    }
    if (Platform.isIOS || Platform.isMacOS) {
      // iOS: link the new asset into the target album (only meaningful
      // for RealAlbum; placeholders don't exist on iOS path).
      if (album is RealAlbum) {
        return PhotoManager.editor.copyAssetToPath(
          asset: asset,
          pathEntity: album.source,
        );
      }
    }
    return asset;
  }

  @override
  Future<List<String>> deleteAssets(List<AssetEntity> assets) {
    final ids = assets.map((a) => a.id).toList();
    return PhotoManager.editor.deleteWithIds(ids);
  }
}
