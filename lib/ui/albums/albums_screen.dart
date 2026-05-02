import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/media_repository.dart';
import '../photos/photos_screen.dart';
import '../snackbar.dart';

class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen> {
  Future<_AlbumsLoadResult>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
  }

  Future<_AlbumsLoadResult> _load() async {
    final repo = ref.read(mediaRepositoryProvider);
    final permission = await repo.requestPermission();
    if (!permission.hasAccess) {
      return _AlbumsLoadResult(permission: permission, albums: const []);
    }
    final albums = await repo.getUserAlbums();
    return _AlbumsLoadResult(permission: permission, albums: albums);
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _showCreateDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _CreateAlbumDialog(),
    );
    if (!mounted) return;
    if (name == null || name.isEmpty) return;

    try {
      await ref.read(mediaRepositoryProvider).createAlbum(name);
      if (!mounted) return;
      _reload();
    } on DuplicateAlbumException {
      if (!mounted) return;
      showError(context, '이미 같은 이름의 앨범이 있습니다');
    } catch (e) {
      if (!mounted) return;
      showError(context, '앨범 생성 실패: $e');
    }
  }

  Future<void> _onPresentLimited() async {
    try {
      await ref.read(mediaRepositoryProvider).presentLimitedPicker();
      if (!mounted) return;
      _reload();
    } catch (e) {
      if (!mounted) return;
      showError(context, '사진 선택을 열 수 없습니다: $e');
    }
  }

  Future<void> _onOpenSettings() async {
    try {
      await openAppSettings();
    } catch (e) {
      if (!mounted) return;
      showError(context, '설정을 열 수 없습니다: $e');
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
      body: SafeArea(
        top: false,
        child: FutureBuilder<_AlbumsLoadResult>(
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
            final isLimited = result.permission.isLimited;
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
      ),
    );
  }

  Widget _albumsBody(_AlbumsLoadResult result) {
    if (result.albums.isEmpty) {
      // RefreshIndicator needs a scrollable child; AlwaysScrollableScrollPhysics
      // gives the empty list pull-to-refresh.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 64),
            child: Center(child: Text('앨범 없음')),
          ),
        ],
      );
    }
    return ListView.builder(
      itemCount: result.albums.length,
      itemBuilder: (context, index) {
        final album = result.albums[index];
        final isPlaceholder = album is PlaceholderAlbum;
        return ListTile(
          leading: Icon(
            isPlaceholder
                ? Icons.photo_album_outlined
                : Icons.photo_library,
          ),
          title: Text(album.name),
          subtitle: Text(
            isPlaceholder ? '사진 추가 대기 중' : '${album.assetCount} items',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => PhotosScreen(album: album),
              ),
            );
            if (!mounted) return;
            _reload();
          },
        );
      },
    );
  }
}

class _AlbumsLoadResult {
  const _AlbumsLoadResult({required this.permission, required this.albums});

  final PermissionState permission;
  final List<AlbumDisplay> albums;
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

class _CreateAlbumDialog extends StatefulWidget {
  const _CreateAlbumDialog();

  @override
  State<_CreateAlbumDialog> createState() => _CreateAlbumDialogState();
}

class _CreateAlbumDialogState extends State<_CreateAlbumDialog> {
  // Owning the controller in a StatefulWidget keeps it alive until the
  // TextField is fully torn down. Disposing it manually right after
  // showDialog() returns races with the FocusNode/TextField teardown.
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('새 앨범'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(hintText: '앨범 이름'),
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        TextButton(onPressed: _submit, child: const Text('만들기')),
      ],
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
