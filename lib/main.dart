import 'package:flutter/material.dart';

import 'app.dart';
import 'data/media_repository.dart';
import 'ui/albums/albums_screen.dart';

void main() {
  runApp(CubbyApp(mediaRepository: PhotoManagerMediaRepository()));
}

class CubbyApp extends StatelessWidget {
  const CubbyApp({super.key, required this.mediaRepository});

  final MediaRepository mediaRepository;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      mediaRepository: mediaRepository,
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
