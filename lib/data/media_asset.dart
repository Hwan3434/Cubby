import 'dart:io' show File;
import 'dart:typed_data';

/// 자산이 어느 데이터 소스에서 왔는지. swap 가능한 repository 구현체별로
/// 한 값. 같은 raw id가 다른 소스에서 우연히 겹쳐도 [MediaAsset.equals]에서
/// 충돌 없이 다뤄진다.
enum AssetSource {
  /// photo_manager AssetEntity 기반.
  photoManager,

  /// (예정) Android MediaStore 직접 query 기반.
  mediaStore,

  /// in-memory bytes를 감싼 합성 자산. 예: native MediaStore에서 가져온
  /// cover thumbnail bytes를 photo_manager가 빠뜨린 자리에 끼워 넣을 때.
  /// originFile/originBytes는 합성 자산 입장에서 의미가 약하지만, cover
  /// 표시 widget이 단일 [MediaAsset]만 받도록 해 분기를 줄인다.
  synthetic,
}

/// UI/cache 레이어가 사용하는 자산 추상 타입.
///
/// 식별은 (source, id) 쌍. id는 각 소스의 raw 식별자(prefix 없음). 컬렉션
/// 키로 쓸 때는 [storageKey]를 사용해 충돌을 방지.
abstract class MediaAsset {
  /// 각 소스의 raw 식별자 (photo_manager AssetEntity.id, MediaStore _ID 등).
  String get id;

  AssetSource get source;

  bool get isVideo;

  DateTime get createdAt;

  int get width;

  int get height;

  /// 영상의 길이. 사진은 `Duration.zero`.
  Duration get duration;

  /// 컬렉션 키. (source, id)로 직렬화해 다른 source의 동일 raw id와 분리.
  String get storageKey => '${source.name}:$id';

  /// 그리드/스트립용 썸네일 bytes (JPEG). 실패 시 null.
  Future<Uint8List?> thumbnail({int size = 240});

  /// 원본 파일. iOS는 photo_manager가 임시 디렉토리로 복사한 path를 줄 수
  /// 있고, Android MediaStore는 실제 storage path. 일부 케이스(접근 실패/
  /// iCloud 미다운로드)에선 null.
  Future<File?> originFile();

  /// 원본 bytes. share 대신 in-memory 디코딩이 필요한 케이스에 사용.
  Future<Uint8List?> originBytes();
}
