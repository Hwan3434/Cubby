import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app.dart';
import '../../domain/models/album.dart';
import '../photos/photos_screen.dart';

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
    final scope = AppScope.of(context);
    final permission = await scope.mediaRepository.requestPermission();
    if (!permission.hasAccess) {
      return _AlbumsLoadResult(permission: permission, albums: const []);
    }
    final entities = await scope.mediaRepository.getUserAlbums();
    final albums = await Future.wait(
      entities.map((e) async {
        final count = await e.assetCountAsync;
        final createdAt = await scope.albumMetaStore.getCreatedAt(e.id);
        return Album(source: e, assetCount: count, createdAt: createdAt);
      }),
    );
    return _AlbumsLoadResult(permission: permission, albums: albums);
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _showCreateDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('새 앨범'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '앨범 이름'),
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('만들기'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (name == null || name.isEmpty) return;

    final scope = AppScope.of(context);
    final album = await scope.mediaRepository.createAlbum(name);
    if (!mounted) return;
    if (album == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Android에서는 첫 사진 촬영 시 앨범이 만들어집니다'),
        ),
      );
      return;
    }
    await scope.albumMetaStore.setCreatedAt(album.id, DateTime.now());
    if (!mounted) return;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Albums')),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateDialog,
        child: const Icon(Icons.add),
      ),
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
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: result.albums.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 200),
                      Center(child: Text('앨범 없음')),
                    ],
                  )
                : ListView.builder(
                    itemCount: result.albums.length,
                    itemBuilder: (context, index) {
                      final album = result.albums[index];
                      return ListTile(
                        title: Text(album.name),
                        subtitle: Text(_subtitle(album)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => PhotosScreen(album: album.source),
                            ),
                          );
                          if (!mounted) return;
                          _reload();
                        },
                      );
                    },
                  ),
          );
        },
      ),
    );
  }

  String _subtitle(Album album) {
    final parts = <String>['${album.assetCount} items'];
    if (album.createdAt != null) {
      parts.add(_formatDate(album.createdAt!));
    }
    return parts.join(' · ');
  }

  String _formatDate(DateTime d) {
    final l = d.toLocal();
    return '${l.year}-${_pad(l.month)}-${_pad(l.day)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

class _AlbumsLoadResult {
  const _AlbumsLoadResult({required this.permission, required this.albums});

  final PermissionState permission;
  final List<Album> albums;
}
