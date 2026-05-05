import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_expandable_fab/flutter_expandable_fab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_router.dart';
import '../../data/album.dart';
import '../../data/album_live.dart';
import '../../data/albums_catalog.dart';
import '../../data/app_preferences.dart';
import '../../data/media_asset.dart';
import '../../data/media_repository.dart';
import '../snackbar.dart';
import '../widgets/asset_thumbnail.dart';
import '../theme/cubby_theme.dart';
import '../theme/cubby_tokens.dart';
import 'grouping.dart';
import 'media_detail_route.dart';

class PhotosScreen extends ConsumerStatefulWidget {
  const PhotosScreen({
    super.key,
    required this.albumName,
    this.album,
    this.shootImmediately = false,
  });

  /// 라우트의 진실 (`/albums/:name`).
  final String albumName;

  /// 라우트 extra로 전달된 [Album] 힌트. 없으면 화면이 직접 lookup.
  /// placeholder 분기용으로 들고 있다.
  final Album? album;

  /// 라우트 진입 직후 자동으로 카메라 push.
  /// "새 앨범 만들기 + 즉시 촬영" 흐름에서 albums가 PhotosScreen을 push하면서
  /// 켜둔다. PhotosScreen은 마운트 직후 카메라를 push하므로 stack은
  /// albums → photos(name) → camera(name) 가 자연스럽게 만들어진다.
  final bool shootImmediately;

  @override
  ConsumerState<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends ConsumerState<PhotosScreen> {
  static const _selectionLimit = 20;

  // 자산 리스트와 페이지네이션은 albumLiveProvider가 소유. 여기는 UI 한정
  // 상태만 — 다중 선택, 정렬, 그룹 단위, 카메라에서 강조할 fresh ID, 그리드
  // 썸네일 캐시.
  final Set<String> _selected = {};

  /// 시스템 back 가로채기용. expanded일 때 첫 번째 back은 FAB만 닫는다.
  final GlobalKey<ExpandableFabState> _fabKey =
      GlobalKey<ExpandableFabState>();
  final Map<String, Uint8List> _thumbBytes = {};
  final Set<String> _freshIds = {};
  bool _selectionMode = false;
  bool _started = false;

  bool _ascending = false;
  GroupingUnit _grouping = GroupingUnit.day;

  String get _albumName => widget.albumName;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _loadGrouping();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(albumLiveProvider(_albumName).notifier).loadMore();
        // "새 앨범 + 즉시 촬영" 흐름: 마운트 직후 카메라를 push해 stack을
        // albums → photos → camera 로 자연스럽게 만든다. 카메라에서 뒤로
        // 가면 PhotosScreen이 그대로 보여 공유 팝업/방금 강조도 정상 동작.
        if (widget.shootImmediately) _openCamera();
      });
    }
  }

  void _loadGrouping() {
    final async = ref.read(appPreferencesProvider);
    async.whenData((prefs) {
      if (!mounted) return;
      setState(() => _grouping = prefs.groupingUnit);
    });
  }

  void _loadMore() {
    ref.read(albumLiveProvider(_albumName).notifier).loadMore();
  }

  void _openDetail(int index, List<MediaAsset> ordered) {
    openMediaDetail(
      context,
      assets: List.unmodifiable(ordered),
      initialIndex: index,
      albumId: _albumName,
      seedThumbs: Map.unmodifiable(_thumbBytes),
      onAssetDeleted: (assetId) {
        if (!mounted) return;
        ref
            .read(albumLiveProvider(_albumName).notifier)
            .removeAssets([assetId]);
        setState(() {
          _selected.remove(assetId);
          _thumbBytes.remove(assetId);
          _freshIds.remove(assetId);
        });
      },
    );
  }

  Future<void> _openCamera() async {
    final savedIds = await context.push<List<String>>(
      AppRoutes.camera(_albumName),
      extra: widget.album,
    );
    if (!mounted || savedIds == null || savedIds.isEmpty) return;
    setState(() => _freshIds.addAll(savedIds));
    await _maybeOfferShare(savedIds);
  }

  Future<void> _maybeOfferShare(List<String> ids) async {
    final shouldShare = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('공유할까요?'),
        content: Text(
          ids.length == 1
              ? '방금 찍은 항목을 다른 앱으로 공유하시겠어요?'
              : '방금 찍은 ${ids.length}개를 다른 앱으로 공유하시겠어요?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('아니요'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('공유'),
          ),
        ],
      ),
    );
    if (!mounted || shouldShare != true) return;
    await _shareByKeys(ids);
  }

  Future<void> _shareSelected() => _shareByKeys(_selected);

  Future<void> _shareByKeys(Iterable<String> storageKeys) async {
    final keys = storageKeys.toSet();
    if (keys.isEmpty) return;
    final items = ref.read(albumLiveProvider(_albumName)).items;
    final assets =
        items.where((a) => keys.contains(a.storageKey)).toList();
    if (assets.isEmpty) return;
    try {
      final files = await Future.wait(assets.map((a) => a.originFile()));
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
    final items = ref.read(albumLiveProvider(_albumName)).items;
    final assets = items.where((a) => _selected.contains(a.storageKey)).toList();
    if (assets.isEmpty) return;
    try {
      final deletedIds = await repo.deleteAssets(assets);
      if (!mounted) return;
      if (deletedIds.isEmpty) return;
      ref
          .read(albumLiveProvider(_albumName).notifier)
          .removeAssets(deletedIds);
      setState(() {
        _selected.clear();
        _selectionMode = false;
      });
    } catch (e) {
      if (!mounted) return;
      showError(context, '삭제 실패: $e');
    }
  }

  /// 앨범 통째 삭제. 앱 자체 확인 다이얼로그 → (system: Android OS의 자산
  /// 삭제 동의 다이얼로그가 한 번 더) → 성공 시 albums 목록으로 pop.
  Future<void> _deleteAlbum() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('앨범 삭제'),
        content: const Text('모든 사진과 앨범이 함께 영구삭제됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('아니요'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC64545),
              foregroundColor: Colors.white,
            ),
            child: const Text('예'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;

    // album 인스턴스: 라우트 extra가 없을 수 있어 catalog에서 우선 lookup.
    Album? album = widget.album;
    if (album == null) {
      for (final a in ref.read(albumsCatalogProvider).albums) {
        if (a.name == _albumName) {
          album = a;
          break;
        }
      }
    }
    if (album == null) return;

    try {
      final ok =
          await ref.read(albumsCatalogProvider.notifier).deleteAlbum(album);
      if (!mounted) return;
      if (ok) {
        context.pop();
      }
      // ok=false는 사용자 OS 다이얼로그 취소 또는 iOS 미구현. silent 종료.
    } catch (e) {
      if (!mounted) return;
      showError(context, '앨범 삭제 실패: $e');
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

  void _toggleSelect(MediaAsset a) {
    if (!a.isSelectable) return;
    if (_selected.contains(a.storageKey)) {
      setState(() => _selected.remove(a.storageKey));
      return;
    }
    if (_selected.length >= _selectionLimit) {
      showError(context, '최대 $_selectionLimit개까지 선택할 수 있습니다');
      return;
    }
    setState(() {
      _selectionMode = true;
      _selected.add(a.storageKey);
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

  /// FAB chip처럼 짧은 공간에 들어가는 한 단어 라벨.
  String _groupingShortLabel(GroupingUnit u) => switch (u) {
        GroupingUnit.day => '일별',
        GroupingUnit.week => '주별',
        GroupingUnit.month => '월별',
      };

  IconData _groupingIcon(GroupingUnit u) => switch (u) {
        GroupingUnit.day => Icons.view_day_outlined,
        GroupingUnit.week => Icons.view_week_outlined,
        GroupingUnit.month => Icons.view_module_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final assetsState = ref.watch(albumLiveProvider(_albumName));
    final items = assetsState.gridItems;
    final loading = assetsState.loading;
    final isPlaceholder =
        (widget.album?.isPlaceholder ?? false) && items.isEmpty;
    final ordered = _orderItems(items);
    final sections = groupAssets(ordered, _grouping);

    // 시스템 back 가로채기: FAB이 펼쳐 있으면 그것부터 닫고, 다중선택
    // 중이면 selection을 해제, 둘 다 아닐 때만 라우트를 pop. canPop은 build
    // 시점에 stale일 수 있어 항상 false로 두고 분기는 핸들러에서.
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final fabState = _fabKey.currentState;
        if (fabState != null && fabState.isOpen) {
          fabState.toggle();
          return;
        }
        if (_selectionMode) {
          _exitSelectionMode();
          return;
        }
        context.pop();
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          bottom: false,
          child: Column(
          children: [
            _DetailAppBar(
              albumName: _albumName,
              itemCount: items.length,
              selectionMode: _selectionMode,
              selectedCount: _selected.length,
              selectionLimit: _selectionLimit,
              onBack: () => context.pop(),
              onEnterSelection: items.isEmpty ? null : _enterSelectionMode,
              onExitSelection: _exitSelectionMode,
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                    _loadMore();
                  }
                  return false;
                },
                child: items.isEmpty && !loading
                    ? _EmptyState(isPlaceholder: isPlaceholder)
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
                              child: loading
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
        floatingActionButtonLocation:
            _selectionMode ? null : ExpandableFab.location,
        floatingActionButton: _selectionMode
            ? null
            : _PhotosFab(
                fabKey: _fabKey,
                onShoot: _openCamera,
                onToggleSort: _toggleSort,
                onCycleGrouping: _cycleGrouping,
                onDeleteAlbum: _deleteAlbum,
                ascending: _ascending,
                groupingIcon: _groupingIcon(_grouping),
                groupingLabel: _groupingShortLabel(_grouping),
              ),
        bottomNavigationBar: _selectionMode
            ? _MultiSelectActionBar(
                selectedCount: _selected.length,
                limit: _selectionLimit,
                onShare: _selected.isEmpty ? null : _shareSelected,
                onDelete: _selected.isEmpty ? null : _deleteSelected,
              )
            : null,
      ),
    );
  }

  // provider items는 desc 정렬 보장. asc 토글이면 reverse.
  List<MediaAsset> _orderItems(List<MediaAsset> items) {
    if (_ascending) return items.reversed.toList(growable: false);
    return items;
  }

  Widget _buildCell(MediaAsset asset, List<MediaAsset> ordered) {
    final selected = _selected.contains(asset.storageKey);
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
        fresh: _freshIds.contains(asset.storageKey),
        cachedBytes: _thumbBytes[asset.storageKey],
        onBytesLoaded: (id, bytes) {
          _thumbBytes[id] = bytes;
        },
      ),
    );
  }
}

class _DetailAppBar extends StatelessWidget {
  const _DetailAppBar({
    required this.albumName,
    required this.itemCount,
    required this.selectionMode,
    required this.selectedCount,
    required this.selectionLimit,
    required this.onBack,
    required this.onEnterSelection,
    required this.onExitSelection,
  });

  final String albumName;
  final int itemCount;
  final bool selectionMode;
  final int selectedCount;
  final int selectionLimit;
  final VoidCallback onBack;
  final VoidCallback? onEnterSelection;
  final VoidCallback onExitSelection;

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
                  selectionMode ? '$selectedCount개 선택됨' : albumName,
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
          if (!selectionMode)
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

class _GridCell extends StatelessWidget {
  const _GridCell({
    required this.asset,
    required this.selected,
    required this.multiSelect,
    required this.fresh,
    required this.cachedBytes,
    required this.onBytesLoaded,
  });

  final MediaAsset asset;
  final bool selected;
  final bool multiSelect;
  final bool fresh;
  final Uint8List? cachedBytes;
  final void Function(String storageKey, Uint8List bytes) onBytesLoaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    final isVideo = asset.isVideo;
    return Stack(
      fit: StackFit.expand,
      children: [
        AssetThumbnail(
          asset: asset,
          size: kGridThumbSize,
          seedBytes: cachedBytes,
          onBytesLoaded: onBytesLoaded,
          placeholder: Container(color: cubby.surfaceCard),
        ),
        if (isVideo && !multiSelect)
          Positioned(
            left: 6,
            bottom: 6,
            child: _VideoDurationPill(duration: asset.duration),
          ),
        if (multiSelect)
          Positioned(
            top: 8,
            right: 8,
            child: _RadioBubble(filled: selected, color: scheme.primary),
          ),
        if (multiSelect && selected)
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.18),
                border: Border.all(color: scheme.primary, width: 2.5),
              ),
            ),
          ),
        if (fresh && !multiSelect) ...[
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: scheme.primary, width: 3),
              ),
            ),
          ),
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius:
                    const BorderRadius.all(Radius.circular(9999)),
              ),
              child: const Text(
                '방금',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
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
                // 삭제 버튼은 light/dark 모두 동일 진빨강 + 흰 텍스트로 고정.
                // ColorScheme.error는 dark에서 light pink로 매핑되어 흰
                // 텍스트와 대비가 깨지기 때문에 brand 의도에 맞춰 직접 지정.
                backgroundColor: const Color(0xFFC64545),
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

/// Speed-dial FAB. 메인 = 촬영(가장 자주 쓰는 동작), 펼치면 정렬 토글 +
/// 그룹 단위 cycle. 다중 선택 모드일 땐 부모가 통째로 안 그리므로 selection
/// 진입 시 펼친 상태가 자연스럽게 닫힌다.
class _PhotosFab extends StatelessWidget {
  const _PhotosFab({
    required this.fabKey,
    required this.onShoot,
    required this.onToggleSort,
    required this.onCycleGrouping,
    required this.onDeleteAlbum,
    required this.ascending,
    required this.groupingIcon,
    required this.groupingLabel,
  });

  /// 부모가 들고 있는 ExpandableFabState 접근용 GlobalKey. 시스템 back으로
  /// FAB을 먼저 닫는 동작에 사용.
  final GlobalKey<ExpandableFabState> fabKey;
  final VoidCallback onShoot;
  final VoidCallback onToggleSort;
  final VoidCallback onCycleGrouping;
  final VoidCallback onDeleteAlbum;
  final bool ascending;
  final IconData groupingIcon;
  final String groupingLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExpandableFab(
      key: fabKey,
      type: ExpandableFabType.up,
      distance: 64,
      // 펼쳤을 때 화면 어둡게 처리 — 보조 동작 강조 + 그리드 흐림.
      overlayStyle: ExpandableFabOverlayStyle(
        color: Colors.black.withValues(alpha: 0.32),
      ),
      openButtonBuilder: RotateFloatingActionButtonBuilder(
        child: const Icon(Icons.photo_camera_outlined, color: Colors.white),
        fabSize: ExpandableFabSize.regular,
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: CubbyRadius.xlAll),
      ),
      closeButtonBuilder: RotateFloatingActionButtonBuilder(
        child: const Icon(Icons.close, color: Colors.white),
        fabSize: ExpandableFabSize.regular,
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: CubbyRadius.xlAll),
      ),
      childrenAnimation: ExpandableFabAnimation.rotate,
      children: [
        // 펼치면 메인 FAB이 닫힘 아이콘으로 morph되어 "촬영" 자체가 child로
        // 한 번 더 노출돼야 사용자가 헷갈리지 않음.
        _FabAction(
          heroTag: 'photos_fab_shoot',
          icon: Icons.photo_camera_outlined,
          label: '촬영',
          onPressed: onShoot,
        ),
        _FabAction(
          heroTag: 'photos_fab_sort',
          icon: ascending ? Icons.arrow_upward : Icons.arrow_downward,
          label: ascending ? '오래된순' : '최신순',
          onPressed: onToggleSort,
        ),
        _FabAction(
          heroTag: 'photos_fab_group',
          icon: groupingIcon,
          label: groupingLabel,
          onPressed: onCycleGrouping,
        ),
        _FabAction(
          heroTag: 'photos_fab_delete',
          icon: Icons.delete_outline,
          label: '앨범 삭제',
          onPressed: onDeleteAlbum,
          danger: true,
        ),
      ],
    );
  }
}

/// child FAB + 좌측 라벨 칩. ExpandableFab.location 기준 우하단에 그려져
/// 라벨이 화면 밖으로 잘리지 않는다. 배경/border는 모든 child에서 동일하게
/// 통일해 메인 FAB(coral)만 강조되도록.
class _FabAction extends StatelessWidget {
  const _FabAction({
    required this.heroTag,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final String heroTag;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// 위험 동작(예: 앨범 삭제). 칩과 FAB 둘 다 빨간 톤으로 강조해 일반 child와
  /// 시각적으로 구분.
  final bool danger;

  static const Color _dangerFg = Color(0xFFC64545);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    final fg = danger ? _dangerFg : scheme.onSurface;
    final borderColor = danger ? _dangerFg.withValues(alpha: 0.45) : cubby.hairline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: CubbySpacing.sm,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: CubbyRadius.mdAll,
            border: Border.all(color: borderColor),
          ),
          child: Text(
            label,
            style: CubbyType.caption.copyWith(
              fontSize: 12,
              color: fg,
              fontWeight: danger ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 10),
        FloatingActionButton.small(
          heroTag: heroTag,
          onPressed: onPressed,
          backgroundColor: scheme.surface,
          foregroundColor: fg,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: CubbyRadius.lgAll,
            side: BorderSide(color: borderColor),
          ),
          tooltip: label,
          child: Icon(icon),
        ),
      ],
    );
  }
}
