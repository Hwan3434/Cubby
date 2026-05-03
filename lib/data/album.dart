/// 앨범의 기원. 실제 시스템 미디어 스토어에 폴더가 존재하는지, 아니면
/// 사용자가 만들었지만 첫 자산 저장 전이라 메모리상에만 있는지 구분.
///
/// `placeholder`는 Android 한정 — iOS/macOS는 `createAlbum`이 즉시 빈
/// 시스템 앨범을 만들 수 있어 첫 진입부터 `system`으로 들어온다. Android는
/// MediaStore가 빈 폴더를 표현 못 해서 첫 저장이 일어날 때까지
/// `placeholder`로 머문다 (design.md §3 Decision 1).
enum AlbumOrigin { system, placeholder }

/// 앨범의 정적 메타데이터. 자산 리스트/cover 같은 동적 부분은 [AlbumLive]
/// (lib/data/album_live.dart)에서 관리하고, 여기서는 식별자(name) +
/// 시스템에 보고된 카운트만 보유.
///
/// `name`이 identity. RealAlbum/PlaceholderAlbum 두 sealed 변종을 통합한
/// 결과로, 앨범 한 개는 lifecycle 동안 같은 name을 유지하고 origin만 바뀐다
/// (placeholder → system 으로 promote).
class Album {
  Album({
    required this.name,
    required this.origin,
    required this.storedCount,
  });

  final String name;
  final AlbumOrigin origin;

  /// MediaRepository가 시스템(예: photo_manager)에서 받은 카운트. placeholder
  /// 인 동안엔 항상 0. 카메라가 방금 저장한 자산이 같은 프로세스의 stale 캐시
  /// 때문에 여기에 안 잡힐 수 있어, 화면은 [AlbumLive.effectiveCount]를 우선
  /// 사용한다.
  final int storedCount;

  bool get isPlaceholder => origin == AlbumOrigin.placeholder;
  bool get isSystem => origin == AlbumOrigin.system;

  @override
  bool operator ==(Object other) =>
      other is Album && other.name == name && other.origin == origin;

  @override
  int get hashCode => Object.hash(name, origin);

  @override
  String toString() => 'Album($name, $origin, stored=$storedCount)';
}
