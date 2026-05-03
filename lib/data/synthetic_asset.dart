import 'dart:io' show File;
import 'dart:typed_data';

import 'media_asset.dart';

/// In-memory bytes를 감싼 합성 자산. cover 표시 widget이 항상 [MediaAsset]
/// 하나만 받도록 native MediaStore에서 가져온 thumbnail bytes를 이쪽으로
/// 흡수. originFile/originBytes는 의미상 cover preview에만 쓰이는 자산이라
/// 둘 다 합성 bytes를 그대로 돌려주거나 null.
class SyntheticImageAsset implements MediaAsset {
  SyntheticImageAsset({
    required this.id,
    required this.bytes,
    required this.createdAt,
  });

  /// caller가 정한 raw id. native cover의 경우 MediaStore _ID 문자열을 그대로
  /// 사용한다. [storageKey]에서 source와 함께 직렬화돼 다른 소스와 충돌 안 함.
  @override
  final String id;

  final Uint8List bytes;

  @override
  AssetSource get source => AssetSource.synthetic;

  @override
  String get storageKey => '${source.name}:$id';

  @override
  bool get isVideo => false;

  @override
  final DateTime createdAt;

  @override
  int get width => 0;

  @override
  int get height => 0;

  @override
  Duration get duration => Duration.zero;

  @override
  Future<Uint8List?> thumbnail({int size = 240}) async => bytes;

  /// 합성 자산은 원본 파일이 없다 — cover 표시용일 뿐, 공유/원본 디코딩은
  /// 호출처가 결코 의도해선 안 된다.
  @override
  Future<File?> originFile() async => null;

  @override
  Future<Uint8List?> originBytes() async => bytes;
}
