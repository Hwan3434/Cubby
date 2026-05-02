import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/media_repository.dart';
import '../camera/camera_screen.dart';
import '../snackbar.dart';
import 'media_detail_route.dart';

class PhotosScreen extends ConsumerStatefulWidget {
  const PhotosScreen({super.key, required this.album});

  final AlbumDisplay album;

  @override
  ConsumerState<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends ConsumerState<PhotosScreen> {
  static const _pageSize = 80;

  // Maximum number of items the user can have selected at once. Hard
  // cap aligned with what the OS share sheet handles reliably; beyond
  // that, sharing/deleting many items at once is fragile across vendors.
  static const _selectionLimit = 20;

  // The album displayed by this screen. Starts as widget.album but may be
  // replaced with the promoted RealAlbum after the first save into a
  // PlaceholderAlbum, so subsequent loads see the real assets.
  late AlbumDisplay _album = widget.album;

  final List<AssetEntity> _items = [];
  final Set<String> _selected = {};
  // Cache of decoded 240px thumbnail bytes the grid is showing right now,
  // keyed by asset.id. We hand the same bytes to the detail route so its
  // Hero destination has pixels on frame 0 of the flight; without this
  // seed, the destination Hero is empty for ~200ms while photo_manager
  // re-fetches the same thumbnail and the transition appears to skip.
  final Map<String, Uint8List> _thumbBytes = {};
  // Tracks whether the selection toolbar is showing. Decoupled from
  // _selected.isNotEmpty so the user can enter selection mode via the
  // AppBar button before picking anything.
  bool _selectionMode = false;
  bool _hasMore = true;
  bool _loading = false;
  int _nextPage = 0;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _loadMore();
    }
  }

  bool get _isPlaceholder => _album is PlaceholderAlbum;

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    // Placeholder albums have no assets yet; skip the platform-channel
    // round-trip and show the empty-state message immediately.
    if (_isPlaceholder) {
      setState(() => _hasMore = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final page = await ref.read(mediaRepositoryProvider).getAssets(
        _album,
        page: _nextPage,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _nextPage++;
        _hasMore = page.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, '사진을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _selected.clear();
      _thumbBytes.clear();
      _nextPage = 0;
      _hasMore = true;
    });
    await _loadMore();
  }

  // After a first-save promotes the placeholder, look up the now-real
  // album by name and swap it in so subsequent loads work.
  Future<void> _promoteIfPlaceholder() async {
    if (!_isPlaceholder) return;
    final albums =
        await ref.read(mediaRepositoryProvider).getUserAlbums();
    if (!mounted) return;
    final promoted = albums.whereType<RealAlbum>().where(
      (a) => a.name == _album.name,
    );
    if (promoted.isNotEmpty) {
      setState(() => _album = promoted.first);
    }
  }

  void _openDetail(int index) {
    openMediaDetail(
      context,
      assets: List.unmodifiable(_items),
      initialIndex: index,
      albumId: _album.name,
      seedThumbs: Map.unmodifiable(_thumbBytes),
      onAssetDeleted: (assetId) {
        if (!mounted) return;
        setState(() {
          _items.removeWhere((a) => a.id == assetId);
          _selected.remove(assetId);
          _thumbBytes.remove(assetId);
        });
      },
    );
  }

  Future<void> _openCamera() async {
    final saved = await Navigator.push<AssetEntity>(
      context,
      MaterialPageRoute(builder: (_) => CameraScreen(album: _album)),
    );
    if (!mounted || saved == null) return;
    await _promoteIfPlaceholder();
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _shareSelected() async {
    final assets = _items.where((a) => _selected.contains(a.id)).toList();
    if (assets.isEmpty) return;
    try {
      final files = await Future.wait(assets.map((a) => a.file));
      final xfiles = [
        for (final f in files)
          if (f != null) XFile(f.path),
      ];
      if (!mounted) return;
      if (xfiles.isEmpty) {
        showError(context, '공유할 파일을 가져오지 못했습니다');
        return;
      }
      await SharePlus.instance.share(ShareParams(files: xfiles));
    } catch (e) {
      if (!mounted) return;
      showError(context, '공유 실패: $e');
    }
  }

  Future<void> _deleteSelected() async {
    final repo = ref.read(mediaRepositoryProvider);
    final assets = _items.where((a) => _selected.contains(a.id)).toList();
    if (assets.isEmpty) return;
    try {
      final deletedIds = await repo.deleteAssets(assets);
      if (!mounted) return;
      if (deletedIds.isEmpty) {
        // user cancelled the OS dialog
        return;
      }
      setState(() {
        _items.removeWhere((a) => deletedIds.contains(a.id));
        _selected.clear();
        _selectionMode = false;
      });
    } catch (e) {
      if (!mounted) return;
      showError(context, '삭제 실패: $e');
    }
  }

  void _enterSelectionMode() {
    if (_selectionMode) return;
    setState(() => _selectionMode = true);
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelect(AssetEntity a) {
    if (_selected.contains(a.id)) {
      setState(() => _selected.remove(a.id));
      return;
    }
    if (_selected.length >= _selectionLimit) {
      showError(context, '최대 $_selectionLimit개까지 선택할 수 있습니다');
      return;
    }
    setState(() {
      _selectionMode = true;
      _selected.add(a.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : null,
        title: Text(
          _selectionMode
              ? '${_selected.length} / $_selectionLimit'
              : _album.name,
        ),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _selected.isEmpty ? null : _shareSelected,
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _selected.isEmpty ? null : _deleteSelected,
            ),
          ] else ...[
            // Hide the select button for placeholder albums (nothing to
            // select yet) and empty real albums.
            if (_items.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.check_box_outlined),
                tooltip: '선택',
                onPressed: _enterSelectionMode,
              ),
            IconButton(
              icon: const Icon(Icons.camera_alt),
              onPressed: _openCamera,
            ),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: _items.isEmpty && !_loading
            ? _EmptyState(isPlaceholder: _isPlaceholder)
            : GridView.builder(
                padding: const EdgeInsets.all(2),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                    ),
                itemCount: _items.length,
                itemBuilder: (context, i) {
                  final asset = _items[i];
                  final selected = _selected.contains(asset.id);
                  return GestureDetector(
                    onLongPress: () => _toggleSelect(asset),
                    onTap: () {
                      if (_selectionMode) {
                        _toggleSelect(asset);
                      } else {
                        _openDetail(i);
                      }
                    },
                    child: _Thumbnail(
                      asset: asset,
                      selected: selected,
                      // Pass any cached bytes synchronously so the
                      // grid cell renders Image.memory(bytes) on the
                      // very first build — same widget structure the
                      // detail Hero uses, which keeps the back-flight
                      // from flickering on rebuild.
                      cachedBytes: _thumbBytes[asset.id],
                      onBytesLoaded: (id, bytes) {
                        _thumbBytes[id] = bytes;
                        // No setState here: _Thumbnail manages its own
                        // local copy and rebuilds itself.
                      },
                    ),
                  );
                },
              ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isPlaceholder});

  final bool isPlaceholder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isPlaceholder
                  ? Icons.photo_camera_outlined
                  : Icons.photo_library_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              isPlaceholder
                  ? '첫 사진 촬영 시 폴더도 생성됩니다'
                  : '사진 없음',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({
    required this.asset,
    required this.selected,
    required this.cachedBytes,
    required this.onBytesLoaded,
  });

  final AssetEntity asset;
  final bool selected;
  // Bytes the parent already has for this asset, if any. When provided
  // we skip the platform-channel fetch entirely — important because
  // after the detail screen pops, GridView re-mounts our cell and we
  // want to render the same Image.memory(bytes) the Hero just landed
  // on, with no FutureBuilder flicker in between.
  final Uint8List? cachedBytes;
  // Called once the 240px JPEG has been decoded. The grid screen uses
  // this to seed the detail route so the Hero flight has matching
  // pixels on both ends.
  final void Function(String assetId, Uint8List bytes) onBytesLoaded;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.cachedBytes;
    if (_bytes == null) _fetch();
  }

  @override
  void didUpdateWidget(_Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      // Cell got recycled to a different asset.
      _bytes = widget.cachedBytes;
      if (_bytes == null) _fetch();
    }
  }

  Future<void> _fetch() async {
    final bytes = await widget.asset.thumbnailDataWithSize(kGridThumbSize);
    if (!mounted || bytes == null) return;
    widget.onBytesLoaded(widget.asset.id, bytes);
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Stack(
      fit: StackFit.expand,
      children: [
        bytes == null
            ? Container(color: Colors.grey.shade300)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        if (widget.asset.type == AssetType.video)
          const Positioned(
            top: 4,
            right: 4,
            child: Icon(Icons.videocam, color: Colors.white, size: 18),
          ),
        if (widget.selected)
          Container(
            color: Colors.black.withValues(alpha: 0.4),
            alignment: Alignment.center,
            child: const Icon(
              Icons.check_circle,
              color: Colors.white,
              size: 32,
            ),
          ),
      ],
    );
  }
}
