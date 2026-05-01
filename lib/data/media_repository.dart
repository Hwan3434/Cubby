import 'package:photo_manager/photo_manager.dart';

abstract class MediaRepository {
  Future<PermissionState> requestPermission();

  Future<List<AssetPathEntity>> getUserAlbums();
}

class PhotoManagerMediaRepository implements MediaRepository {
  @override
  Future<PermissionState> requestPermission() {
    return PhotoManager.requestPermissionExtend();
  }

  @override
  Future<List<AssetPathEntity>> getUserAlbums() {
    return PhotoManager.getAssetPathList(
      type: RequestType.common,
      onlyAll: false,
      hasAll: false,
    );
  }
}
