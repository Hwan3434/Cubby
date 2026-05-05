import 'dart:io' show File;
import 'dart:typed_data';

import 'media_asset.dart';

/// native MediaStore에서 받은 자산을 [MediaAsset] 인터페이스로 감싼다.
/// [filePath]가 있으면 detail/share에서 진짜 파일을 디코딩, 없으면 cover
/// thumbnail 전용.
class SyntheticImageAsset implements MediaAsset {
  SyntheticImageAsset({
    required this.id,
    required this.bytes,
    required this.createdAt,
    this.filePath,
    this.isVideo = false,
    this.duration = Duration.zero,
  });

  @override
  final String id;

  final Uint8List bytes;

  final String? filePath;

  @override
  AssetSource get source => AssetSource.synthetic;

  // image와 video는 MediaStore에서 _ID가 별도 namespace라 isVideo로 구분.
  @override
  String get storageKey => '${source.name}:${isVideo ? "v" : "i"}$id';

  // photo_manager AssetEntity가 없어 시스템 삭제 경로를 못 타므로 selection
  // 대상 아님. 다음 refresh에서 photo_manager가 fresh를 따라잡으면 같은 파일이
  // photo_manager 자산으로 들어와 selectable이 됨.
  @override
  bool get isSelectable => false;

  @override
  final bool isVideo;

  @override
  final DateTime createdAt;

  @override
  int get width => 0;

  @override
  int get height => 0;

  @override
  final Duration duration;

  @override
  Future<Uint8List?> thumbnail({int size = 240}) async => bytes;

  @override
  Future<File?> originFile() async {
    final p = filePath;
    if (p == null) return null;
    final f = File(p);
    return await f.exists() ? f : null;
  }

  @override
  Future<Uint8List?> originBytes() async {
    final f = await originFile();
    if (f != null) {
      try {
        return await f.readAsBytes();
      } catch (_) {/* fall through */}
    }
    return bytes;
  }
}
