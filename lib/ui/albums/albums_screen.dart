import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app.dart';

class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});

  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  Future<_AlbumsLoadResult>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  Future<_AlbumsLoadResult> _load() async {
    final repo = AppScope.of(context).mediaRepository;
    final permission = await repo.requestPermission();
    if (!permission.hasAccess) {
      return _AlbumsLoadResult(permission: permission, albums: const []);
    }
    final albums = await repo.getUserAlbums();
    return _AlbumsLoadResult(permission: permission, albums: albums);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Albums')),
      body: FutureBuilder<_AlbumsLoadResult>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final result = snapshot.data!;
          if (!result.permission.hasAccess) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '사진 라이브러리 접근 권한이 필요합니다.\n'
                  '설정에서 권한을 허용해주세요.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (result.albums.isEmpty) {
            return const Center(child: Text('앨범 없음'));
          }
          return ListView.builder(
            itemCount: result.albums.length,
            itemBuilder: (context, index) {
              final album = result.albums[index];
              return ListTile(
                title: Text(album.name),
              );
            },
          );
        },
      ),
    );
  }
}

class _AlbumsLoadResult {
  const _AlbumsLoadResult({required this.permission, required this.albums});

  final PermissionState permission;
  final List<AssetPathEntity> albums;
}
