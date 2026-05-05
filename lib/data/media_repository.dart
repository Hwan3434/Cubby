import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import 'album.dart';
import 'media_asset.dart';
import 'media_refresh.dart';
import 'photo_manager_asset.dart';

/// App-wide MediaRepository. Always returns a [PhotoManagerMediaRepository]
/// in production; tests override the provider in [ProviderScope] to swap
/// in a fake.
final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => PhotoManagerMediaRepository(),
);

/// Thrown by [MediaRepository.createAlbum] when an album with the same
/// name already exists (system or in-memory placeholder).
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
  Future<List<Album>> getUserAlbums();

  /// Create a new album with the given name.
  ///
  /// - iOS/macOS: creates an empty system album immediately
  ///   ([Album.origin] = system).
  /// - Android: registers an in-memory placeholder ([Album.origin] =
  ///   placeholder). The actual `Pictures/<name>/` folder materialises
  ///   only when the first asset is saved into it via [saveImage] or
  ///   [saveVideo], which also promotes the placeholder to system on the
  ///   next list refresh.
  ///
  /// Throws [DuplicateAlbumException] if any album (system or placeholder)
  /// with the same name already exists.
  Future<Album> createAlbum(String name);

  /// Assets in [album], paged. Default sort is createdAt descending.
  /// Returns empty for placeholder albums.
  Future<List<MediaAsset>> getAssets(
    Album album, {
    int page = 0,
    int pageSize = 80,
  });

  /// Save a captured image into [album].
  ///
  /// If [album] is a placeholder, the first save creates the underlying
  /// system folder (Android) and the placeholder is removed from the
  /// in-memory list on the next [getUserAlbums] refresh.
  Future<MediaAsset> saveImage({
    required Uint8List bytes,
    required String filename,
    required Album album,
  });

  Future<MediaAsset> saveVideo({
    required File file,
    required String filename,
    required Album album,
  });

  /// Delete the given assets. Returns the IDs ([MediaAsset.storageKey])
  /// that were successfully deleted. Android 11+ and iOS show a system
  /// confirmation dialog automatically.
  Future<List<String>> deleteAssets(List<MediaAsset> assets);

  /// 앨범과 그 안의 모든 자산을 삭제.
  ///
  /// - placeholder: 메모리상에서만 제거 (system 호출 없음). 항상 true.
  /// - system (Android 11+/iOS): 시스템 동의 다이얼로그가 자동으로 뜸. 사용자가
  ///   허용하면 true, 취소하면 false. 빈 디렉토리도 함께 정리한다.
  ///
  /// 반환값이 true면 호출자는 catalog/live state를 갱신해 UI를 동기화해야 한다.
  Future<bool> deleteAlbum(Album album);
}

class PhotoManagerMediaRepository implements MediaRepository {
  // Placeholder albums live only for the lifetime of the process. Losing
  // them on restart is intentional per the design call: an album the user
  // never put a photo into shouldn't persist.
  final List<String> _placeholderNames = [];

  // 시스템 앨범 lookup용 캐시 (name → AssetPathEntity). UI에는 노출되지
  // 않으며, 자산 페이징/저장 시 photo_manager 호출에 필요한 path를 찾는
  // 데만 사용. getUserAlbums가 호출될 때마다 갱신된다.
  final Map<String, AssetPathEntity> _pathCache = {};

  @override
  Future<PermissionState> requestPermission() {
    return PhotoManager.requestPermissionExtend();
  }

  @override
  Future<void> presentLimitedPicker() async {
    await PhotoManager.presentLimited();
  }

  // 모든 path가 createDateTime desc 정렬 컨텍스트를 갖도록 명시. 명시 안
  // 하면 photo_manager 내부 기본값에 따라 플랫폼별로 결과 순서가 달라져
  // 앨범 cover에 가장 오래된 자산이 잡히는 케이스가 생긴다 (design.md §3
  // Decision 2 — 촬영일 desc 고정).
  static final _descByCreateDate = FilterOptionGroup(
    orders: [
      const OrderOption(type: OrderOptionType.createDate, asc: false),
    ],
  );

  Future<List<AssetPathEntity>> _systemAlbums() {
    return PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
      hasAll: false,
      filterOption: _descByCreateDate,
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
  Future<List<Album>> getUserAlbums() async {
    // photo_manager의 system albums + native MediaStore의 bucket summary를 병렬로
    // 받아 합친다. native summary는 photo_manager가 stale로 누락한 bucket을
    // 보강하는 용도 — 외부 카메라가 막 만든 폴더, cubby 자체 카메라가 saveImage
    // 직후 인식 못 한 폴더 등. iOS는 native summary가 빈 map이라 영향 없음.
    final systemF = _systemAlbums();
    final nativeSummaryF = fetchBucketSummary();
    final system = await systemF;
    final realAlbums = await Future.wait(
      system.map((e) async {
        AssetPathEntity refreshed;
        try {
          refreshed = await e.fetchPathProperties(
                filterOptionGroup: _descByCreateDate,
              ) ??
              e;
        } catch (err) {
          debugPrint('[repo] ${e.name} fetchPathProperties ERROR: $err');
          refreshed = e;
        }
        final count = await refreshed.assetCountAsync;
        return MapEntry(
          refreshed,
          Album(
            name: refreshed.name,
            origin: AlbumOrigin.system,
            storedCount: count,
          ),
        );
      }),
    );
    _pathCache
      ..clear()
      ..addEntries(
        realAlbums.map((entry) => MapEntry(entry.key.name, entry.key)),
      );
    final albums = realAlbums.map((entry) => entry.value).toList();
    final knownNames = albums.map((a) => a.name).toSet();
    final nativeSummary = await nativeSummaryF;
    // photo_manager가 못 본 native bucket을 system으로 보강. _pathCache에는
    // entity가 없지만 albumLive의 nativeRecents 보강이 자산 표시를 채운다.
    for (final entry in nativeSummary.entries) {
      if (!knownNames.add(entry.key)) continue;
      albums.add(Album(
        name: entry.key,
        origin: AlbumOrigin.system,
        storedCount: entry.value,
      ));
    }
    _placeholderNames.removeWhere(knownNames.contains);
    final placeholderAlbums = _placeholderNames.map(
      (name) => Album(
        name: name,
        origin: AlbumOrigin.placeholder,
        storedCount: 0,
      ),
    );
    return [...albums, ...placeholderAlbums];
  }

  @override
  Future<Album> createAlbum(String name) async {
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
        throw DuplicateAlbumException(name);
      }
      _pathCache[created.name] = created;
      final count = await created.assetCountAsync;
      return Album(
        name: created.name,
        origin: AlbumOrigin.system,
        storedCount: count,
      );
    }

    // Android: register placeholder, materialised on first asset save.
    _placeholderNames.add(name);
    return Album(
      name: name,
      origin: AlbumOrigin.placeholder,
      storedCount: 0,
    );
  }

  @override
  Future<List<MediaAsset>> getAssets(
    Album album, {
    int page = 0,
    int pageSize = 80,
  }) async {
    if (album.isPlaceholder) return const [];
    final source = await _resolvePath(album.name);
    if (source == null) return const [];
    final entities = await source.getAssetListPaged(
      page: page,
      size: pageSize,
    );
    return entities.map(PhotoManagerAsset.new).toList();
  }

  @override
  Future<MediaAsset> saveImage({
    required Uint8List bytes,
    required String filename,
    required Album album,
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
  Future<MediaAsset> saveVideo({
    required File file,
    required String filename,
    required Album album,
  }) async {
    // 사진/영상 같은 root(Pictures/<name>/) 통일 — 한 폴더 = 한 앨범. photo_manager
    // 가 BUCKET_DISPLAY_NAME 같아도 root path 다르면 별개 bucket으로 보는 함정 회피.
    // design.md Decision 5 참고.
    final relativePath = await _resolveRelativePath(
      album,
      mediaRoot: 'Pictures',
    );
    final asset = await PhotoManager.editor.saveVideo(
      file,
      title: filename,
      relativePath: relativePath,
    );
    return _afterSave(asset: asset, album: album);
  }

  /// 캐시된 path가 없으면 system query로 한 번 더 lookup. 외부에서 폴더가
  /// 새로 생긴 직후 (placeholder의 첫 저장 등) 캐시 미스를 방어한다.
  Future<AssetPathEntity?> _resolvePath(String name) async {
    final cached = _pathCache[name];
    if (cached != null) return cached;
    final found = await _findSystemAlbumByName(name);
    if (found != null) _pathCache[name] = found;
    return found;
  }

  /// system album이면 기존 bucket path 재사용 (Android에서 같은 이름 폴더가
  /// 두 개로 갈라지는 사고 방지). placeholder면 mediaRoot/<name>/ 컨벤션으로
  /// 새 폴더 materialise. iOS는 relativePath 무시.
  Future<String> _resolveRelativePath(
    Album album, {
    required String mediaRoot,
  }) async {
    if (album.isSystem) {
      final source = await _resolvePath(album.name);
      final existing = await source?.relativePathAsync;
      if (existing != null && existing.isNotEmpty) return existing;
    }
    return '$mediaRoot/${album.name}';
  }

  Future<MediaAsset> _afterSave({
    required AssetEntity asset,
    required Album album,
  }) async {
    // 첫 저장 직후 photo_manager의 같은-프로세스 binder cache는 새로
    // 만들어진 시스템 폴더(예: Pictures/소주)를 아직 못 볼 수 있다. 여기서
    // placeholder를 즉시 지우면 그 사이 상위 레이어가 getUserAlbums를 받아
    // 앨범 목록에서 통째로 사라지는 케이스가 발생한다. placeholder는
    // getUserAlbums에서 system과 이름이 겹칠 때만 정리하도록 유지.
    if ((Platform.isIOS || Platform.isMacOS) && album.isSystem) {
      // iOS: link the new asset into the target album.
      final source = await _resolvePath(album.name);
      if (source != null) {
        final linked = await PhotoManager.editor.copyAssetToPath(
          asset: asset,
          pathEntity: source,
        );
        return PhotoManagerAsset(linked);
      }
    }
    return PhotoManagerAsset(asset);
  }

  @override
  Future<bool> deleteAlbum(Album album) async {
    // placeholder는 사용자가 그 자리에서 카메라로 자산을 저장한 직후일 수 있다.
    // 이 짧은 window에선 우리 프로세스 ContentResolver binder cache가 stale이라
    // native query가 0건으로 떨어져 OS 다이얼로그 없이 빈 success가 나온다. 그
    // 케이스에만 cache를 비우고 MediaScanner를 한 번 통과시켜 fresh 보장. 오래
    // 안정된 RealAlbum에는 prep 비용을 매번 부담하지 않는다.
    if (album.isPlaceholder) {
      await scanCameraDirs();
      try {
        await PhotoManager.releaseCache();
      } catch (e) {
        debugPrint('[deleteAlbum] releaseCache error: $e');
      }
      _placeholderNames.remove(album.name);
    }
    final ok = await deleteAlbumNative(album.name);
    if (ok) {
      _pathCache.remove(album.name);
    }
    return ok;
  }

  @override
  Future<List<String>> deleteAssets(List<MediaAsset> assets) async {
    // photo_manager 호출은 raw AssetEntity ID가 필요. 다른 소스 자산이
    // 섞여 있을 수 있으니 photoManager 소스만 추려서 처리한다.
    final pmAssets = assets.whereType<PhotoManagerAsset>().toList();
    final pmIds = pmAssets.map((a) => a.entity.id).toList();
    if (pmIds.isEmpty) return const [];
    final deletedRawIds = await PhotoManager.editor.deleteWithIds(pmIds);
    final deletedRawSet = deletedRawIds.toSet();
    return [
      for (final a in pmAssets)
        if (deletedRawSet.contains(a.entity.id)) a.storageKey,
    ];
  }
}
