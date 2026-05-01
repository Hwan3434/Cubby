import 'package:flutter/material.dart';

import 'data/album_meta_store.dart';
import 'data/media_repository.dart';

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.mediaRepository,
    required this.albumMetaStore,
    required super.child,
  });

  final MediaRepository mediaRepository;
  final AlbumMetaStore albumMetaStore;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope not found in widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      mediaRepository != oldWidget.mediaRepository ||
      albumMetaStore != oldWidget.albumMetaStore;
}
