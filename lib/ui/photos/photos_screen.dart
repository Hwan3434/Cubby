import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/app_preferences.dart';
import '../../data/media_repository.dart';
import '../camera/camera_screen.dart';
import '../snackbar.dart';
import '../theme/cubby_theme.dart';
import '../theme/cubby_tokens.dart';
import 'grouping.dart';
import 'media_detail_route.dart';

class PhotosScreen extends ConsumerStatefulWidget {
  const PhotosScreen({super.key, required this.album});

  final AlbumDisplay album;

  @override
  ConsumerState<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends ConsumerState<PhotosScreen> {
  static const _pageSize = 80;
  static const _selectionLimit = 20;

  late AlbumDisplay _album = widget.album;

  final List<AssetEntity> _items = [];
  final Set<String> _selected = {};
  final Map<String, Uint8List> _thumbBytes = {};
  bool _selectionMode = false;
  bool _hasMore = true;
  bool _loading = false;
  int _nextPage = 0;
  bool _started = false;

  // 정렬은 세션 한정 (화면 떠나면 desc로 초기화).
  bool _ascending = false;
  // 그룹 단위는 글로벌 + 영속. AppPreferences에서 로드.
  GroupingUnit _grouping = GroupingUnit.day;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _loadGrouping();
      _loadMore();
    }
  }

  void _loadGrouping() {
    final async = ref.read(appPreferencesProvider);
    async.whenData((prefs) {
      if (!mounted) return;
      setState(() => _grouping = prefs.groupingUnit);
    });
  }

  bool get _isPlaceholder => _album is PlaceholderAlbum;

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
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
        // photo_manager가 사진과 영상을 따로 모아 페이지로 주는 것으로
        // 보여, 시각적으로 type별 그룹이 분리된다. type 무관 촬영일 desc로
        // 정렬해 같은 날짜 라벨 안에 사진과 영상이 함께 보이게 한다.
        _items.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
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

  Future<void> _promoteIfPlaceholder() async {
    if (!_isPlaceholder) return;
    final albums = await ref.read(mediaRepositoryProvider).getUserAlbums();
    if (!mounted) return;
    final promoted = albums.whereType<RealAlbum>().where(
          (a) => a.name == _album.name,
        );
    if (promoted.isNotEmpty) {
      setState(() => _album = promoted.first);
    }
  }

  void _openDetail(int index, List<AssetEntity> ordered) {
    openMediaDetail(
      context,
      assets: List.unmodifiable(ordered),
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
      if (deletedIds.isEmpty) return;
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

  void _toggleSort() {
    setState(() => _ascending = !_ascending);
  }

  Future<void> _cycleGrouping() async {
    final next = switch (_grouping) {
      GroupingUnit.day => GroupingUnit.week,
      GroupingUnit.week => GroupingUnit.month,
      GroupingUnit.month => GroupingUnit.day,
    };
    setState(() => _grouping = next);

    // 영속화 + 안내 (첫 실행 후 3일 이내).
    final asyncPrefs = ref.read(appPreferencesProvider);
    final prefs = asyncPrefs.value;
    if (prefs == null) return;
    await prefs.setGroupingUnit(next);
    if (!mounted) return;
    final age = DateTime.now().difference(prefs.firstLaunchAt);
    if (age <= const Duration(days: 3)) {
      showInfo(context, _groupingLabel(next));
    }
  }

  String _groupingLabel(GroupingUnit u) => switch (u) {
        GroupingUnit.day => '일자 단위로 봅니다',
        GroupingUnit.week => '주 단위로 봅니다',
        GroupingUnit.month => '월 단위로 봅니다',
      };

  IconData _groupingIcon(GroupingUnit u) => switch (u) {
        GroupingUnit.day => Icons.view_day_outlined,
        GroupingUnit.week => Icons.view_week_outlined,
        GroupingUnit.month => Icons.view_module_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ordered = _orderedItems();
    final sections = groupAssets(ordered, _grouping);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _DetailAppBar(
              album: _album,
              itemCount: _items.length,
              selectionMode: _selectionMode,
              selectedCount: _selected.length,
              selectionLimit: _selectionLimit,
              ascending: _ascending,
              groupingUnit: _grouping,
              groupingIcon: _groupingIcon(_grouping),
              onBack: () => Navigator.pop(context),
              onEnterSelection: _items.isEmpty ? null : _enterSelectionMode,
              onExitSelection: _exitSelectionMode,
              onToggleSort: _items.isEmpty ? null : _toggleSort,
              onCycleGrouping: _items.isEmpty ? null : _cycleGrouping,
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                    _loadMore();
                  }
                  return false;
                },
                child: _items.isEmpty && !_loading
                    ? _EmptyState(isPlaceholder: _isPlaceholder)
                    : CustomScrollView(
                        slivers: [
                          for (final section in sections) ...[
                            SliverToBoxAdapter(
                              child: _SectionHeader(label: section.label),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              sliver: SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  crossAxisSpacing: 2,
                                  mainAxisSpacing: 2,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) {
                                    final asset = section.items[i];
                                    return _buildCell(asset, ordered);
                                  },
                                  childCount: section.items.length,
                                ),
                              ),
                            ),
                          ],
                          SliverToBoxAdapter(
                            child: SizedBox(
                              height: _selectionMode ? 96 : 110,
                              child: _loading
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _openCamera,
              icon: const Icon(Icons.photo_camera_outlined,
                  color: Colors.white),
              label: Text(
                '앨범에 촬영',
                style: CubbyType.buttonLabel.copyWith(color: Colors.white),
              ),
              backgroundColor: scheme.primary,
              foregroundColor: Colors.white,
              elevation: 6,
              shape: const RoundedRectangleBorder(
                borderRadius: CubbyRadius.xlAll,
              ),
            ),
      bottomNavigationBar: _selectionMode
          ? _MultiSelectActionBar(
              selectedCount: _selected.length,
              limit: _selectionLimit,
              onShare: _selected.isEmpty ? null : _shareSelected,
              onDelete: _selected.isEmpty ? null : _deleteSelected,
            )
          : null,
    );
  }

  // _items는 _loadMore에서 desc로 정렬돼 들어온다. asc 토글이면 reverse.
  List<AssetEntity> _orderedItems() {
    if (_ascending) return _items.reversed.toList(growable: false);
    return _items;
  }

  Widget _buildCell(AssetEntity asset, List<AssetEntity> ordered) {
    final selected = _selected.contains(asset.id);
    return GestureDetector(
      onLongPress: () => _toggleSelect(asset),
      onTap: () {
        if (_selectionMode) {
          _toggleSelect(asset);
        } else {
          final i = ordered.indexOf(asset);
          if (i >= 0) _openDetail(i, ordered);
        }
      },
      child: _GridCell(
        asset: asset,
        selected: selected,
        multiSelect: _selectionMode,
        cachedBytes: _thumbBytes[asset.id],
        onBytesLoaded: (id, bytes) {
          _thumbBytes[id] = bytes;
        },
      ),
    );
  }
}

class _DetailAppBar extends StatelessWidget {
  const _DetailAppBar({
    required this.album,
    required this.itemCount,
    required this.selectionMode,
    required this.selectedCount,
    required this.selectionLimit,
    required this.ascending,
    required this.groupingUnit,
    required this.groupingIcon,
    required this.onBack,
    required this.onEnterSelection,
    required this.onExitSelection,
    required this.onToggleSort,
    required this.onCycleGrouping,
  });

  final AlbumDisplay album;
  final int itemCount;
  final bool selectionMode;
  final int selectedCount;
  final int selectionLimit;
  final bool ascending;
  final GroupingUnit groupingUnit;
  final IconData groupingIcon;
  final VoidCallback onBack;
  final VoidCallback? onEnterSelection;
  final VoidCallback onExitSelection;
  final VoidCallback? onToggleSort;
  final VoidCallback? onCycleGrouping;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, CubbySpacing.xs),
      child: Row(
        children: [
          IconButton(
            onPressed: selectionMode ? onExitSelection : onBack,
            icon: Icon(
              selectionMode ? Icons.close : Icons.chevron_left,
              color: scheme.onSurface,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selectionMode ? '$selectedCount개 선택됨' : album.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CubbyType.titleMd.copyWith(color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  selectionMode ? '최대 $selectionLimit개' : '$itemCount개',
                  style: CubbyType.caption.copyWith(color: cubby.muted),
                ),
              ],
            ),
          ),
          if (!selectionMode) ...[
            IconButton(
              onPressed: onEnterSelection,
              icon: Icon(
                Icons.check_circle_outline,
                color: onEnterSelection == null
                    ? cubby.mutedSoft
                    : scheme.onSurface,
              ),
              tooltip: '다중 선택',
            ),
            IconButton(
              onPressed: onCycleGrouping,
              icon: Icon(
                groupingIcon,
                color: onCycleGrouping == null
                    ? cubby.mutedSoft
                    : scheme.onSurface,
              ),
              tooltip: '그룹 단위',
            ),
            IconButton(
              onPressed: onToggleSort,
              icon: Icon(
                ascending ? Icons.arrow_upward : Icons.arrow_downward,
                color: onToggleSort == null
                    ? cubby.mutedSoft
                    : scheme.onSurface,
              ),
              tooltip: '정렬',
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cubby = context.cubby;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CubbySpacing.md,
        20,
        CubbySpacing.md,
        CubbySpacing.xs,
      ),
      child: Text(
        label,
        style: CubbyType.captionUpper.copyWith(
          fontSize: 12,
          color: cubby.muted,
          letterSpacing: 1.3,
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
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: cubby.surfaceCard,
                borderRadius: CubbyRadius.xxlAll,
                border: Border.all(color: cubby.hairline),
              ),
              child: Icon(
                isPlaceholder
                    ? Icons.photo_camera_outlined
                    : Icons.photo_library_outlined,
                size: 36,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: CubbySpacing.lg),
            Text(
              isPlaceholder ? '첫 촬영을 기다리는 중' : '아직 사진이 없어요',
              style: CubbyType.displaySm.copyWith(
                fontSize: 22,
                letterSpacing: -0.2,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              isPlaceholder
                  ? '카메라 버튼을 눌러 첫 사진을 찍으면\n앨범 폴더가 함께 생성됩니다.'
                  : '아래 카메라 버튼으로 시작하세요.',
              textAlign: TextAlign.center,
              style: CubbyType.bodySm.copyWith(color: cubby.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _GridCell extends StatefulWidget {
  const _GridCell({
    required this.asset,
    required this.selected,
    required this.multiSelect,
    required this.cachedBytes,
    required this.onBytesLoaded,
  });

  final AssetEntity asset;
  final bool selected;
  final bool multiSelect;
  final Uint8List? cachedBytes;
  final void Function(String assetId, Uint8List bytes) onBytesLoaded;

  @override
  State<_GridCell> createState() => _GridCellState();
}

class _GridCellState extends State<_GridCell> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.cachedBytes;
    if (_bytes == null) _fetch();
  }

  @override
  void didUpdateWidget(_GridCell old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
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
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    final bytes = _bytes;
    final isVideo = widget.asset.type == AssetType.video;
    return Stack(
      fit: StackFit.expand,
      children: [
        bytes == null
            ? Container(color: cubby.surfaceCard)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        if (isVideo && !widget.multiSelect)
          Positioned(
            left: 6,
            bottom: 6,
            child: _VideoDurationPill(duration: widget.asset.videoDuration),
          ),
        if (widget.multiSelect)
          Positioned(
            top: 8,
            right: 8,
            child: _RadioBubble(filled: widget.selected, color: scheme.primary),
          ),
        if (widget.multiSelect && widget.selected)
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.18),
                border: Border.all(color: scheme.primary, width: 2.5),
              ),
            ),
          ),
      ],
    );
  }
}

class _VideoDurationPill extends StatelessWidget {
  const _VideoDurationPill({required this.duration});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final mm = duration.inMinutes;
    final ss = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final text = '$mm:$ss';
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 7, 3),
      decoration: const BoxDecoration(
        color: Color(0xA8141413),
        borderRadius: BorderRadius.all(Radius.circular(9999)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_arrow, size: 10, color: Color(0xFFFAF9F5)),
          const SizedBox(width: 3),
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Color(0xFFFAF9F5),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadioBubble extends StatelessWidget {
  const _RadioBubble({required this.filled, required this.color});

  final bool filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? color : Colors.black.withValues(alpha: 0.25),
        border: Border.all(
          color: filled ? color : Colors.white.withValues(alpha: 0.85),
          width: 2,
        ),
      ),
      child: filled
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }
}

class _MultiSelectActionBar extends StatelessWidget {
  const _MultiSelectActionBar({
    required this.selectedCount,
    required this.limit,
    required this.onShare,
    required this.onDelete,
  });

  final int selectedCount;
  final int limit;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    final limitHit = selectedCount >= limit;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cubby.canvas,
          border: Border(top: BorderSide(color: cubby.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(
          CubbySpacing.md,
          CubbySpacing.sm,
          CubbySpacing.md,
          14,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                limitHit
                    ? '한 번에 최대 $limit개까지'
                    : '$selectedCount개 선택 · 최대 $limit개',
                style: CubbyType.caption.copyWith(color: cubby.muted),
              ),
            ),
            OutlinedButton.icon(
              onPressed: limitHit ? null : onShare,
              icon: const Icon(Icons.ios_share, size: 18),
              label: const Text('공유'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
                side: BorderSide(color: cubby.hairline),
                foregroundColor: scheme.onSurface,
                shape: const RoundedRectangleBorder(
                  borderRadius: CubbyRadius.mdAll,
                ),
                textStyle: CubbyType.buttonLabel,
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: Colors.white),
              label: const Text('삭제'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                backgroundColor: scheme.error,
                foregroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: CubbyRadius.mdAll,
                ),
                textStyle: CubbyType.buttonLabel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
