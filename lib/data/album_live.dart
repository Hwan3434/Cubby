import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'album.dart';
import 'albums_catalog.dart';
import 'media_asset.dart';
import 'media_refresh.dart';
import 'media_repository.dart';
import 'synthetic_asset.dart';

/// per-album live state. items + native cover + 페이지네이션을 한 객체에서
/// 관리하고, 화면이 필요한 derived값(effectiveCount, cover)을 그 위에서
/// 노출. catalog의 [Album]은 정적 메타(이름/origin/시스템 카운트)만 책임.
class AlbumLive {
  const AlbumLive({
    required this.items,
    required this.nativeCover,
    required this.hasMore,
    required this.nextPage,
    required this.loading,
  });

  const AlbumLive.initial()
      : items = const [],
        nativeCover = null,
        hasMore = true,
        nextPage = 0,
        loading = false;

  /// 페이지네이션된 자산 리스트. createdAt desc.
  final List<MediaAsset> items;

  /// photo_manager가 같은 프로세스에서 가장 최신 자산을 빠뜨릴 때 native
  /// MediaStore에서 가져온 cover를 합성 자산으로 감싼 것. 더 최신이면
  /// [cover]에서 우선 노출.
  final SyntheticImageAsset? nativeCover;

  final bool hasMore;
  final int nextPage;
  final bool loading;

  AlbumLive copyWith({
    List<MediaAsset>? items,
    SyntheticImageAsset? nativeCover,
    bool resetNativeCover = false,
    bool? hasMore,
    int? nextPage,
    bool? loading,
  }) {
    return AlbumLive(
      items: items ?? this.items,
      nativeCover:
          resetNativeCover ? null : (nativeCover ?? this.nativeCover),
      hasMore: hasMore ?? this.hasMore,
      nextPage: nextPage ?? this.nextPage,
      loading: loading ?? this.loading,
    );
  }
}

/// Live 상태 위에서 derive되는 값들. UI는 이걸 통해 cover/카운트를 본다.
extension AlbumLiveDerived on AlbumLive {
  /// items 중 가장 최신, 없으면 null. items는 createdAt desc 정렬을 가정.
  MediaAsset? get latestItem => items.isEmpty ? null : items.first;

  /// cover로 표시할 자산. native가 더 최신이면 native를 우선.
  MediaAsset? coverFor(Album album) {
    final pm = latestItem;
    final native = nativeCover;
    if (native == null) return pm;
    if (pm == null) return native;
    return native.createdAt.isAfter(pm.createdAt) ? native : pm;
  }

  /// 화면에 표시할 카운트. catalog의 storedCount가 photo_manager stale 때문에
  /// 뒤처질 때 items.length가 더 정확해 그쪽을 우선.
  int effectiveCountWith(Album album) {
    return items.length > album.storedCount
        ? items.length
        : album.storedCount;
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
    // watch만 해도 첫 페이지가 자동 로드되도록 lazy fetch 발사. provider는
    // autoDispose라 화면이 더 이상 보지 않으면 정리되고, 다음 watch 때 다시
    // build → fetch가 일어난다. cover 표시용으로 albums 목록이 N개 앨범을
    // 동시에 watch하는 케이스도 자연스럽게 cover를 채워준다.
    Future.microtask(() {
      if (_disposed) return;
      loadMore();
    });
    return const AlbumLive.initial();
  }

  /// 자산을 fetch할 때 쓸 album 인스턴스를 찾는다. catalog에 이미 있으면
  /// 그쪽을 사용 — N개 앨범이 동시에 watch되면 N번 photo_manager round-trip이
  /// 일어나는 N+1 비용을 막는다. catalog가 비어있는 cold start에서만
  /// repository에 직접 묻고, 그 결과는 본 화면이 별도로 catalog에 캐시하지
  /// 않는다(catalog 자체가 갱신될 때 다음 호출은 hot path).
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
        state = state.copyWith(loading: false, hasMore: false);
        if (isFirstPage) await _refreshNativeCover();
        return;
      }
      final repo = ref.read(mediaRepositoryProvider);
      final page = await repo.getAssets(
        album,
        page: state.nextPage,
        pageSize: _pageSize,
      );
      if (_disposed) return;
      final merged = [...state.items, ...page]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      state = state.copyWith(
        items: merged,
        hasMore: page.length == _pageSize,
        nextPage: state.nextPage + 1,
        loading: false,
      );
      // native cover는 cover 표시용 우회. 첫 페이지에서만 받으면 충분.
      if (isFirstPage) await _refreshNativeCover();
    } catch (e) {
      debugPrint('[live $albumName] loadMore error: $e');
      if (!_disposed) state = state.copyWith(loading: false);
    }
  }

  Future<void> refresh() async {
    if (_disposed) return;
    state = const AlbumLive.initial();
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

  /// photo_manager 우회용 native cover를 갱신. 같은 프로세스 binder cache가
  /// 새 자산을 못 보는 동안에도 cover가 최신을 따라가게 한다.
  Future<void> _refreshNativeCover() async {
    final native = await fetchLatestCoverNative(albumName);
    if (_disposed) return;
    if (native == null) {
      state = state.copyWith(resetNativeCover: true);
      return;
    }
    state = state.copyWith(
      nativeCover: SyntheticImageAsset(
        id: native.id.toString(),
        bytes: native.bytes,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(native.effectiveTakenMs),
      ),
    );
  }
}

final albumLiveProvider = NotifierProvider.autoDispose
    .family<AlbumLiveNotifier, AlbumLive, String>(
  AlbumLiveNotifier.new,
);
