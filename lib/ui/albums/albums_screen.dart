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
    try {
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('앨범 생성 실패: $e')),
      );
    }
  }

  Future<void> _onPresentLimited() async {
    try {
      await AppScope.of(context).mediaRepository.presentLimitedPicker();
      if (!mounted) return;
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('사진 선택을 열 수 없습니다: $e')),
      );
    }
  }

  Future<void> _onOpenSettings() async {
    try {
      await AppScope.of(context).mediaRepository.openSystemSettings();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('설정을 열 수 없습니다: $e')),
      );
    }
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
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '앨범을 불러오지 못했습니다.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _reload,
                      child: const Text('다시 시도'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final result = snapshot.data!;
          if (!result.permission.hasAccess) {
            return _PermissionDeniedView(onOpenSettings: _onOpenSettings);
          }
          final isLimited = result.permission == PermissionState.limited;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: Column(
              children: [
                if (isLimited) _LimitedBanner(onTap: _onPresentLimited),
                Expanded(child: _albumsBody(result)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _albumsBody(_AlbumsLoadResult result) {
    if (result.albums.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 200),
          Center(child: Text('앨범 없음')),
        ],
      );
    }
    return ListView.builder(
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

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '사진 라이브러리 접근 권한이 필요합니다.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onOpenSettings,
              child: const Text('설정 열기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LimitedBanner extends StatelessWidget {
  const _LimitedBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 20),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('일부 사진만 접근이 허용되어 있어요'),
              ),
              TextButton(onPressed: onTap, child: const Text('더 추가')),
            ],
          ),
        ),
      ),
    );
  }
}
