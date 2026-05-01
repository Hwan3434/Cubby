import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../../app.dart';
import '../camera/camera_screen.dart';
import '../snackbar.dart';
import 'photo_detail_screen.dart';

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key, required this.album});

  final AssetPathEntity album;

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  static const _pageSize = 80;

  final List<AssetEntity> _items = [];
  final Set<String> _selected = {};
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

  bool get _selectionMode => _selected.isNotEmpty;

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await AppScope.of(context).mediaRepository.getAssets(
        widget.album,
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
      _nextPage = 0;
      _hasMore = true;
    });
    await _loadMore();
  }

  Future<void> _openCamera() async {
    final saved = await Navigator.push<AssetEntity>(
      context,
      MaterialPageRoute(builder: (_) => CameraScreen(album: widget.album)),
    );
    if (!mounted || saved == null) return;
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
    final repo = AppScope.of(context).mediaRepository;
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
      });
    } catch (e) {
      if (!mounted) return;
      showError(context, '삭제 실패: $e');
    }
  }

  void _toggleSelect(AssetEntity a) {
    setState(() {
      if (_selected.contains(a.id)) {
        _selected.remove(a.id);
      } else {
        _selected.add(a.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(_selected.clear),
              )
            : null,
        title: Text(
          _selectionMode ? '${_selected.length} selected' : widget.album.name,
        ),
        actions: [
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: _shareSelected,
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteSelected,
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.camera_alt),
              onPressed: _openCamera,
            ),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
            _loadMore();
          }
          return false;
        },
        child: _items.isEmpty && !_loading
            ? const Center(child: Text('사진 없음'))
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
                        Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PhotoDetailScreen(
                              assets: List<AssetEntity>.from(_items),
                              initialIndex: i,
                            ),
                          ),
                        );
                      }
                    },
                    child: _Thumbnail(asset: asset, selected: selected),
                  );
                },
              ),
      ),
    );
  }
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.asset, required this.selected});

  final AssetEntity asset;
  final bool selected;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  // Resolve the thumbnail once per asset; rebuilding the Stack on
  // selection changes must not retrigger the platform-channel call.
  late Future<Uint8List?> _future = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize.square(240),
  );

  @override
  void didUpdateWidget(_Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _future = widget.asset.thumbnailDataWithSize(
        const ThumbnailSize.square(240),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<Uint8List?>(
          future: _future,
          builder: (context, snap) {
            if (snap.data == null) {
              return Container(color: Colors.grey.shade300);
            }
            return Image.memory(
              snap.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          },
        ),
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
