import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'album.dart';
import 'albums_catalog.dart';
import 'media_asset.dart';
import 'media_refresh.dart';
import 'media_repository.dart';
import 'synthetic_asset.dart';

/// per-album live state. [gridItems]는 생성 시 한 번 계산되어 매 build마다
/// 재계산되지 않는다.
class AlbumLive {
  AlbumLive({
    required this.items,
    required this.nativeRecents,
    required this.hasMore,
    required this.nextPage,
    required this.loading,
  }) : gridItems = _mergeForGrid(items, nativeRecents);

  AlbumLive.initial()
      : items = const [],
        nativeRecents = const [],
        gridItems = const [],
        hasMore = true,
        nextPage = 0,
        loading = false;

  /// photo_manager에서 받은 자산. createdAt desc.
  final List<MediaAsset> items;

  /// native MediaStore에서 직접 받은 보강용. createdAt desc.
  final List<SyntheticImageAsset> nativeRecents;

  /// [items] 위에 [nativeRecents] 중 더 최신인 것을 끼워넣은 결과. dedup 비교가
  /// 초 단위인 이유는 native는 ms까지, photo_manager는 초까지만 들고 있어 같은
  /// 파일이라도 ms 부분이 달라 보이기 때문.
  final List<MediaAsset> gridItems;

  final bool hasMore;
  final int nextPage;
  final bool loading;

  AlbumLive copyWith({
    List<MediaAsset>? items,
    List<SyntheticImageAsset>? nativeRecents,
    bool? hasMore,
    int? nextPage,
    bool? loading,
  }) {
    return AlbumLive(
      items: items ?? this.items,
      nativeRecents: nativeRecents ?? this.nativeRecents,
      hasMore: hasMore ?? this.hasMore,
      nextPage: nextPage ?? this.nextPage,
      loading: loading ?? this.loading,
    );
  }

  static List<MediaAsset> _mergeForGrid(
    List<MediaAsset> items,
    List<SyntheticImageAsset> recents,
  ) {
    if (recents.isEmpty) return items;
    if (items.isEmpty) return List<MediaAsset>.from(recents);
    final maxItemSec = items.first.createdAt.millisecondsSinceEpoch ~/ 1000;
    final extras = recents
        .where((n) => n.createdAt.millisecondsSinceEpoch ~/ 1000 > maxItemSec)
        .toList();
    if (extras.isEmpty) return items;
    return [...extras, ...items];
  }
}

extension AlbumLiveDerived on AlbumLive {
  /// 화면에 표시할 카운트. photo_manager stale로 catalog/items가 새 자산을
  /// 누락한 동안에도 native fallback을 합친 [gridItems]가 진실에 가깝다.
  int effectiveCountWith(Album album) {
    final base = gridItems.length;
    return base > album.storedCount ? base : album.storedCount;
  }
}

class AlbumLiveNotifier extends Notifier<AlbumLive> {
  AlbumLiveNotifier(this.albumName);

  final String albumName;
  static const _pageSize = 80;

  // autoDispose 후 비동기 콜백이 ref.read/state= 를 호출하면 throw됨.
  bool _disposed = false;

  @override
  AlbumLive build() {
    ref.onDispose(() => _disposed = true);
    // 첫 watch 때 자동으로 첫 페이지 로드. autoDispose라 화면이 떠나면 정리되고
    // 다음 watch 때 다시 build→fetch.
    Future.microtask(() {
      if (_disposed) return;
      loadMore();
    });
    return AlbumLive.initial();
  }

  /// catalog hit이면 photo_manager round-trip 회피 (N개 앨범 동시 watch 시 N+1
  /// 비용 방지). cold start에서만 repository에 묻는다.
  Future<Album?> _resolveAlbum() async {
    for (final a in ref.read(albumsCatalogProvider).albums) {
      if (a.name == albumName) return a;
    }
    final albums = await ref.read(mediaRepositoryProvider).getUserAlbums();
    if (_disposed) return null;
    for (final a in albums) {
      if (a.name == albumName) return a;
    }
    return null;
  }

  Future<void> loadMore() async {
    if (_disposed || state.loading || !state.hasMore) return;
    final isFirstPage = state.nextPage == 0;
    state = state.copyWith(loading: true);
    try {
      final album = await _resolveAlbum();
      if (_disposed) return;
      if (album == null || album.isPlaceholder) {
        final native = isFirstPage ? await _fetchNativeRecents() : null;
        if (_disposed) return;
        state = state.copyWith(
          loading: false,
          hasMore: false,
          nativeRecents: native ?? state.nativeRecents,
        );
        return;
      }
      final repo = ref.read(mediaRepositoryProvider);
      // 첫 페이지는 page + nativeRecents + nativeIds(외부 삭제 cull용)를 병렬로
      // 받아 first-paint 단축. 후속 페이지는 append만.
      final pageF = repo.getAssets(album, page: state.nextPage, pageSize: _pageSize);
      final nativeF = isFirstPage ? _fetchNativeRecents() : Future.value(null);
      final nativeIdsF = isFirstPage
          ? fetchAssetIdsByBucket(albumName)
          : Future.value(const <NativeAssetId>{});
      final page = await pageF;
      final native = await nativeF;
      final nativeIds = await nativeIdsF;
      if (_disposed) return;
      // photo_manager가 stale로 자산 일부를 빠뜨릴 수 있다(옛 자산 → 신규 자산
      // 직후, 또는 외부 삭제 직후 빠뜨린 자산이 다음 query에서 누락). 첫
      // 페이지면 native MediaStore ID set과 cross-check:
      //   1) page 중 native에 없는 자산은 외부 삭제된 stale → 제거
      //   2) 옛 items 중 native에 있지만 page에 빠진 자산은 photo_manager가
      //      누락한 stale → 보존
      // nativeIds가 비면 (iOS — id 형식이 다르고 빈 set, 또는 native 실패)
      // photo_manager 결과를 신뢰. base는 옛 items 통째로 둬서 깜빡임 없음.
      final List<MediaAsset> merged;
      if (!isFirstPage) {
        merged = [...state.items, ...page]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } else if (nativeIds.isEmpty) {
        merged = [...page]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } else {
        bool inNative(MediaAsset a) {
          if (a.source != AssetSource.photoManager) return true;
          final id = int.tryParse(a.id);
          if (id == null) return true;
          return nativeIds.contains(NativeAssetId(id: id, isVideo: a.isVideo));
        }
        final pageKeys = page.map((a) => a.storageKey).toSet();
        final preserved = state.items
            .where((a) => inNative(a) && !pageKeys.contains(a.storageKey));
        merged = [...page.where(inNative), ...preserved]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
      state = state.copyWith(
        items: merged,
        hasMore: page.length == _pageSize,
        nextPage: state.nextPage + 1,
        loading: false,
        nativeRecents: native ?? state.nativeRecents,
      );
    } catch (e) {
      debugPrint('[live $albumName] loadMore error: $e');
      if (!_disposed) state = state.copyWith(loading: false);
    }
  }

  /// 옛 items/nativeRecents를 유지한 채 다시 첫 페이지부터 받는다 — [loadMore]가
  /// 새 페이지를 받는 순간 통째 swap되어 깜빡임 없음.
  Future<void> refresh() async {
    if (_disposed) return;
    state = state.copyWith(
      hasMore: true,
      nextPage: 0,
      loading: false,
    );
    await loadMore();
  }

  /// 카메라가 새로 저장한 자산을 즉시 리스트 앞에 끼워 넣는다. 동시에
  /// catalog에 album 메타 갱신을 트리거 — placeholder→system promote가
  /// 동기화되도록.
  void addAsset(MediaAsset asset) {
    if (_disposed) return;
    if (state.items.any((a) => a.storageKey == asset.storageKey)) return;
    final merged = [asset, ...state.items]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = state.copyWith(items: merged);
    ref.read(albumsCatalogProvider.notifier).invalidateAlbum(albumName);
  }

  void removeAssets(Iterable<String> storageKeys) {
    if (_disposed) return;
    final set = storageKeys.toSet();
    if (set.isEmpty) return;
    state = state.copyWith(
      items: state.items
          .where((a) => !set.contains(a.storageKey))
          .toList(),
    );
    ref.read(albumsCatalogProvider.notifier).invalidateAlbum(albumName);
  }

  /// 옛 [AlbumLive.nativeRecents]와 내용이 같으면 같은 reference를 반환해
  /// reference-equality 기반 알림이 무의미한 rebuild를 일으키지 않게 한다.
  /// fetch 실패/미지원이면 null — 호출자는 옛 값 유지.
  Future<List<SyntheticImageAsset>?> _fetchNativeRecents() async {
    final recents = await fetchRecentByBucket(albumName);
    if (_disposed || recents.isEmpty) return null;
    final next = recents
        .map(
          (r) => SyntheticImageAsset(
            id: r.id.toString(),
            bytes: r.bytes,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r.effectiveTakenMs),
            filePath: r.data,
            isVideo: r.isVideo,
            duration: Duration(milliseconds: r.durationMs),
          ),
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final old = state.nativeRecents;
    if (_recentsEqual(old, next)) return old;
    return next;
  }

  static bool _recentsEqual(
    List<SyntheticImageAsset> a,
    List<SyntheticImageAsset> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.isVideo != y.isVideo ||
          x.createdAt != y.createdAt) {
        return false;
      }
    }
    return true;
  }
}

final albumLiveProvider = NotifierProvider.autoDispose
    .family<AlbumLiveNotifier, AlbumLive, String>(
  AlbumLiveNotifier.new,
);
