import 'package:photo_manager/photo_manager.dart';

class Album {
  const Album({
    required this.source,
    required this.assetCount,
    required this.createdAt,
  });

  final AssetPathEntity source;
  final int assetCount;
  final DateTime? createdAt;

  String get id => source.id;
  String get name => source.name;
}
