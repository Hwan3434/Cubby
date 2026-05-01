import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/album_meta_store.dart';
import 'data/media_repository.dart';
import 'ui/albums/albums_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AlbumMetaStore metaStore;
  try {
    final prefs = await SharedPreferences.getInstance();
    metaStore = SharedPreferencesAlbumMetaStore(prefs);
  } catch (_) {
    // Disk full / corrupt prefs / first-boot edge: fall back to memory.
    metaStore = InMemoryAlbumMetaStore();
  }
  runApp(
    CubbyApp(
      mediaRepository: PhotoManagerMediaRepository(),
      albumMetaStore: metaStore,
    ),
  );
}

class CubbyApp extends StatelessWidget {
  const CubbyApp({
    super.key,
    required this.mediaRepository,
    required this.albumMetaStore,
  });

  final MediaRepository mediaRepository;
  final AlbumMetaStore albumMetaStore;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      mediaRepository: mediaRepository,
      albumMetaStore: albumMetaStore,
      child: MaterialApp(
        title: 'Cubby',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const AlbumsScreen(),
      ),
    );
  }
}
