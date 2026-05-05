import 'dart:io' show File;
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'media_asset.dart';

/// photo_manager의 [AssetEntity]를 [MediaAsset] 인터페이스에 맞춰 감싼다.
/// iOS 전체 + Android placeholder/저장 경로에서 사용.
class PhotoManagerAsset implements MediaAsset {
  PhotoManagerAsset(this.entity);

  final AssetEntity entity;

  @override
  String get id => entity.id;

  @override
  AssetSource get source => AssetSource.photoManager;

  @override
  String get storageKey => '${source.name}:$id';

  @override
  bool get isSelectable => true;

  @override
  bool get isVideo => entity.type == AssetType.video;

  @override
  DateTime get createdAt => entity.createDateTime;

  @override
  int get width => entity.width;

  @override
  int get height => entity.height;

  @override
  Duration get duration => entity.videoDuration;

  @override
  Future<Uint8List?> thumbnail({int size = 240}) {
    return entity.thumbnailDataWithSize(ThumbnailSize.square(size));
  }

  @override
  Future<File?> originFile() => entity.file;

  @override
  Future<Uint8List?> originBytes() => entity.originBytes;
}
