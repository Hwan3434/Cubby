import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';

import 'album.dart';
import 'media_repository.dart';

/// 앨범 목록 화면이 watch하는 단일 진실. 권한 + [Album] 리스트만 책임.
/// cover/카운트의 라이브 부분은 [albumLiveProvider](각 앨범별)가 들고,
/// 화면이 둘을 합쳐 보여준다.
class AlbumsCatalogState {
  const AlbumsCatalogState({
    required this.permission,
    required this.albums,
  });

  factory AlbumsCatalogState.initial() => const AlbumsCatalogState(
        permission: PermissionState.notDetermined,
        albums: [],
      );

  final PermissionState permission;
  final List<Album> albums;

  AlbumsCatalogState copyWith({
    PermissionState? permission,
    List<Album>? albums,
  }) {
    return AlbumsCatalogState(
      permission: permission ?? this.permission,
      albums: albums ?? this.albums,
    );
  }
}

class AlbumsCatalogNotifier extends Notifier<AlbumsCatalogState> {
  @override
  AlbumsCatalogState build() => AlbumsCatalogState.initial();

  /// 권한 + 전체 앨범 리스트를 다시 받아온다. lifecycle resumed 또는
  /// pull-to-refresh, presentLimitedPicker 직후에서 호출.
  Future<void> refresh() async {
    final repo = ref.read(mediaRepositoryProvider);
    final permission = await repo.requestPermission();
    if (!permission.hasAccess) {
      state = state.copyWith(
        permission: permission,
        albums: const [],
      );
      return;
    }
    final albums = await repo.getUserAlbums();
    state = AlbumsCatalogState(permission: permission, albums: albums);
  }

  /// 단일 앨범의 메타 갱신. 카메라가 새 자산을 저장한 직후 호출되어
  /// placeholder → system 으로의 promote가 catalog state에 반영되게 한다.
  /// 같은 이름 앨범이 system에서 사라졌다면 placeholder로 간주해 둔 채로
  /// 유지(목록에 그대로 보임).
  Future<void> invalidateAlbum(String name) async {
    final repo = ref.read(mediaRepositoryProvider);
    final albums = await repo.getUserAlbums();
    state = state.copyWith(albums: albums);
  }
}

final albumsCatalogProvider =
    NotifierProvider<AlbumsCatalogNotifier, AlbumsCatalogState>(
  AlbumsCatalogNotifier.new,
);
