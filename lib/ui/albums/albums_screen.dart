import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../app_router.dart';
import '../../data/album.dart';
import '../../data/album_live.dart';
import '../../data/albums_catalog.dart';
import '../../data/app_preferences.dart';
import '../../data/media_asset.dart';
import '../../data/media_refresh.dart';
import '../../data/media_repository.dart';
import '../snackbar.dart';
import '../widgets/asset_thumbnail.dart';
import '../theme/cubby_theme.dart';
import '../theme/cubby_tokens.dart';
import '../widgets/cubby_mark.dart';
import 'new_album_sheet.dart';

class AlbumsScreen extends ConsumerStatefulWidget {
  const AlbumsScreen({super.key});

  @override
  ConsumerState<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends ConsumerState<AlbumsScreen>
    with WidgetsBindingObserver {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(albumsCatalogProvider.notifier).refresh();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshFromExternal();
    }
  }

  Future<void> _refreshFromExternal() async {
    // Native MediaScanner로 MediaProvider에 commit 강제. photo_manager가
    // 같은 프로세스에서 외부 변경을 못 보는 문제 우회. 이후 catalog refresh.
    await scanCameraDirs();
    if (!mounted) return;
    try {
      await PhotoManager.releaseCache();
    } catch (_) {}
    if (!mounted) return;
    await ref.read(albumsCatalogProvider.notifier).refresh();
  }

  Future<void> _showCreateSheet() async {
    final result = await showNewAlbumSheet(context);
    if (!mounted || result == null) return;
    try {
      final repo = ref.read(mediaRepositoryProvider);
      final album = await repo.createAlbum(result.name);
      if (!mounted) return;
      // 신규 placeholder/real album이 즉시 목록에 보이도록 catalog 갱신.
      ref.read(albumsCatalogProvider.notifier).invalidateAlbum(album.name);
      if (result.shootImmediately) {
        // stack-natural한 흐름: albums → photos(name) → camera(name).
        // PhotosScreen이 shoot=1을 받아 마운트 직후 자동으로 카메라를 push.
        // 카메라가 pop되면 stack 위 PhotosScreen이 자연스럽게 보이고,
        // 한 번 더 뒤로가면 albums로.
        await context.push<void>(
          AppRoutes.albumWithImmediateShoot(album.name),
          extra: album,
        );
        // catalog는 카메라의 addAsset이 invalidate해 줘서 별도 reload 불필요.
      }
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
      await ref.read(albumsCatalogProvider.notifier).refresh();
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
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(albumsCatalogProvider);
    final permission = state.permission;
    Widget body;
    if (permission == PermissionState.notDetermined) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!permission.hasAccess) {
      body = _PermissionDeniedView(onOpenSettings: _onOpenSettings);
    } else {
      body = _AlbumsBody(
        state: state,
        onRefresh: _refreshFromExternal,
        onPresentLimited: _onPresentLimited,
      );
    }
    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      floatingActionButton: _CubbyFab(
        icon: Icons.add,
        label: '새 앨범',
        onPressed: _showCreateSheet,
      ),
      backgroundColor: scheme.surface,
    );
  }
}

class _AlbumsBody extends ConsumerWidget {
  const _AlbumsBody({
    required this.state,
    required this.onRefresh,
    required this.onPresentLimited,
  });

  final AlbumsCatalogState state;
  final Future<void> Function() onRefresh;
  final VoidCallback onPresentLimited;

  String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => '시스템 테마',
        ThemeMode.light => '라이트 모드',
        ThemeMode.dark => '다크 모드',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = state.albums;
    final isLimited = state.permission.isLimited;
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;

    Future<void> onTitleTap() async {
      await ref.read(themeModeProvider.notifier).cycle();
      if (!context.mounted) return;
      final mode = ref.read(themeModeProvider);
      showInfo(context, _themeLabel(mode));
    }

    final subtitle = albums.isEmpty
        ? '아직 앨범이 없어요. 첫 앨범부터 시작해 보세요.'
        : '${albums.length}개';

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            // 위로 살짝 스크롤하면 큰 타이틀이 즉시 다시 나오게(snap+floating).
            // 아래로 스크롤할 땐 사라져 그리드가 화면을 채움. 작은 collapsed
            // 타이틀은 노출하지 않고 큰 타이틀이 통째로 들고 나는 식.
            floating: true,
            snap: true,
            pinned: false,
            elevation: 0,
            backgroundColor: scheme.surface,
            surfaceTintColor: Colors.transparent,
            // collapsed 상태일 때 보일 작은 영역. 큰 타이틀이 사라진 직후
            // 자연스럽게 0으로 줄어들도록 toolbar height 0.
            toolbarHeight: 0,
            expandedHeight: _largeAppBarHeight(context),
            flexibleSpace: FlexibleSpaceBar(
              background: _LargeAppBar(
                title: '앨범',
                subtitle: subtitle,
                leading: const CubbyMark(size: 20),
                onTitleTap: onTitleTap,
              ),
              collapseMode: CollapseMode.pin,
            ),
          ),
          if (isLimited)
            SliverToBoxAdapter(
              child: _LimitedBanner(onTap: onPresentLimited),
            ),
          if (albums.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyAlbumsState(),
            )
          else
            SliverLayoutBuilder(
              builder: (context, constraints) {
                // 셀 너비 = (가용 너비 - padding ×2 - spacing) / 2.
                // 셀 높이 = cardPaddingTop + cover + coverGap + 이름줄
                //          + titleCountGap + 카운트줄 + cardPaddingBottom.
                // 텍스트 줄 높이는 TextPainter로 실제 측정 → 폰트 변경/
                // 디바이스 폰트 스케일에도 정확히 맞춤.
                const horizontalPadding = CubbySpacing.md;
                const crossAxisSpacing = CubbySpacing.sm;
                const cardPaddingH = _AlbumCard.cardPaddingH;
                const cardPaddingTop = _AlbumCard.cardPaddingTop;
                const cardPaddingBottom = _AlbumCard.cardPaddingBottom;
                const coverGap = CubbySpacing.sm;
                const titleCountGap = _AlbumCard.titleCountGap;

                final gridWidth =
                    constraints.crossAxisExtent - horizontalPadding * 2;
                final cellWidth = (gridWidth - crossAxisSpacing) / 2;
                final coverSize = cellWidth - cardPaddingH * 2;

                final titleHeight = _measureTextHeight(
                  context: context,
                  sample: '앨범 이름',
                  style: CubbyType.titleSm.copyWith(
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                );
                final countHeight = _measureTextHeight(
                  context: context,
                  sample: '0개',
                  style: CubbyType.caption.copyWith(color: cubby.muted),
                );

                final cellHeight = cardPaddingTop +
                    coverSize +
                    coverGap +
                    titleHeight +
                    titleCountGap +
                    countHeight +
                    cardPaddingBottom;

                return SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    horizontalPadding,
                    CubbySpacing.xs,
                    horizontalPadding,
                    120,
                  ),
                  sliver: SliverGrid(
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: crossAxisSpacing,
                      mainAxisSpacing: CubbySpacing.sm,
                      mainAxisExtent: cellHeight,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => _AlbumCard(album: albums[i]),
                      childCount: albums.length,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// SliverAppBar expandedHeight 계산. _LargeAppBar 안의 leading mark + sm gap
/// + display title + bodySm subtitle + 자체 padding(xs+md+md)에 해당하는
/// 실제 픽셀을 잡아 SliverAppBar에 넘긴다. 폰트 스케일에도 자동 동기화.
double _largeAppBarHeight(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  final cubby = context.cubby;
  final titleHeight = _measureTextHeight(
    context: context,
    sample: '앨범',
    style: CubbyType.displayMd.copyWith(
      fontSize: 32,
      letterSpacing: -0.5,
      color: scheme.onSurface,
    ),
  );
  final subtitleHeight = _measureTextHeight(
    context: context,
    sample: '0개',
    style: CubbyType.bodySm.copyWith(color: cubby.muted),
  );
  // _LargeAppBar 안 padding/spacing 합:
  //   top xs(4) + leading 20 + sm(8) + title + 4 + subtitle + bottom md(16).
  return CubbySpacing.xs +
      20 +
      CubbySpacing.sm +
      titleHeight +
      4 +
      subtitleHeight +
      CubbySpacing.md;
}

class _LargeAppBar extends StatelessWidget {
  const _LargeAppBar({
    required this.title,
    this.subtitle,
    this.leading,
    this.onTitleTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CubbySpacing.md,
        CubbySpacing.xs,
        CubbySpacing.md,
        CubbySpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) leading!,
          const SizedBox(height: CubbySpacing.sm),
          GestureDetector(
            onTap: onTitleTap,
            behavior: HitTestBehavior.opaque,
            child: Text(
              title,
              style: CubbyType.displayMd.copyWith(
                fontSize: 32,
                letterSpacing: -0.5,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: CubbyType.bodySm.copyWith(color: cubby.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 그리드의 한 셀. 정사각 cover 영역 + 이름/카운트.
/// cover 영역은 [_CoverPager]로 최근 N장 좌우 swipe.
/// 카드 자체 탭은 PhotosScreen 진입.
class _AlbumCard extends ConsumerWidget {
  const _AlbumCard({required this.album});

  final Album album;

  static const int _previewLimit = 5;

  // 그리드의 셀 높이 계산이 카드 내부 spacing을 정확히 알아야 해서 노출.
  // 값이 바뀌면 albums_screen의 LayoutBuilder 계산이 자동 동기화된다.
  static const double cardPaddingH = CubbySpacing.xs;
  static const double cardPaddingTop = CubbySpacing.xs;
  // 하단은 시각적 균형용으로 살짝 더 — 텍스트 baseline이 위에 몰려 있어
  // 균일 padding이면 아래쪽이 너무 타이트해 보임.
  static const double cardPaddingBottom = CubbySpacing.xs + 3;
  static const double titleCountGap = 1;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;

    final live = ref.watch(albumLiveProvider(album.name));
    final effectiveCount = live.effectiveCountWith(album);
    final isEmpty = effectiveCount == 0;

    // cover 미리보기에 사용할 자산. items가 있으면 거기서, 없을 땐 native
    // cover를 단일 fallback으로 끼워 넣어 placeholder 상황에서도 cover가
    // 비지 않게 한다.
    final assets = <MediaAsset>[];
    if (live.items.isNotEmpty) {
      assets.addAll(live.items.take(_previewLimit));
    } else if (live.nativeCover != null) {
      assets.add(live.nativeCover!);
    }

    return Material(
      color: cubby.surfaceCard,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: cubby.hairline, width: 1),
        borderRadius: CubbyRadius.lgAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(AppRoutes.album(album.name), extra: album),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            cardPaddingH,
            cardPaddingTop,
            cardPaddingH,
            cardPaddingBottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: _CoverPager(empty: isEmpty, assets: assets),
              ),
              const SizedBox(height: CubbySpacing.sm),
              Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CubbyType.titleSm.copyWith(
                  fontSize: 14,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: titleCountGap),
              Text(
                isEmpty ? '비어 있음' : '$effectiveCount개',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CubbyType.caption.copyWith(color: cubby.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 정사각 cover 영역에서 최근 자산을 좌우 swipe로 미리보기. 점 dot
/// 인디케이터를 우하단에 작게.
class _CoverPager extends StatefulWidget {
  const _CoverPager({required this.empty, required this.assets});

  final bool empty;
  final List<MediaAsset> assets;

  @override
  State<_CoverPager> createState() => _CoverPagerState();
}

class _CoverPagerState extends State<_CoverPager> {
  late final PageController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void didUpdateWidget(_CoverPager old) {
    super.didUpdateWidget(old);
    // 리스트가 줄어 현재 index가 범위를 벗어나면 0으로 reset.
    if (_index >= widget.assets.length && widget.assets.isNotEmpty) {
      _index = 0;
      _controller.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubby = context.cubby;
    if (widget.empty) {
      return _DottedBorder(
        color: cubby.hairline,
        radius: CubbyRadius.lg,
        child: Container(
          decoration: BoxDecoration(
            color: cubby.surfaceCard,
            borderRadius: CubbyRadius.lgAll,
          ),
          child: Icon(
            Icons.image_outlined,
            size: 28,
            color: cubby.mutedSoft,
          ),
        ),
      );
    }
    if (widget.assets.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: cubby.surfaceCard,
          borderRadius: CubbyRadius.lgAll,
        ),
        child: Icon(
          Icons.photo_library_outlined,
          size: 28,
          color: cubby.muted,
        ),
      );
    }
    return ClipRRect(
      borderRadius: CubbyRadius.lgAll,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.assets.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) =>
                AssetThumbnail(
                  asset: widget.assets[i],
                  // 셀 가로가 화면 절반에 가까워 240보다 살짝 큰 사이즈로.
                  size: 360,
                  placeholder:
                      Container(color: context.cubby.surfaceCard),
                ),
          ),
          if (widget.assets.length > 1)
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: _CoverDots(
                count: widget.assets.length,
                index: _index,
              ),
            ),
        ],
      ),
    );
  }
}

class _CoverDots extends StatelessWidget {
  const _CoverDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++) ...[
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: i == index ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index
                  ? Colors.white.withValues(alpha: 0.95)
                  : Colors.white.withValues(alpha: 0.45),
              borderRadius: const BorderRadius.all(Radius.circular(9999)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
          if (i != count - 1) const SizedBox(width: 4),
        ],
      ],
    );
  }
}

/// dashed border outline. Flutter엔 기본 dashed border가 없어 페인터로.
class _DottedBorder extends StatelessWidget {
  const _DottedBorder({
    required this.color,
    required this.radius,
    required this.child,
  });

  final Color color;
  final Radius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});
  final Color color;
  final Radius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      radius,
    );
    final path = Path()..addRRect(rrect);
    final dashPath = Path();
    const dashWidth = 4.0;
    const dashGap = 3.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        final next = (dist + dashWidth).clamp(0.0, metric.length);
        dashPath.addPath(metric.extractPath(dist, next), Offset.zero);
        dist = next + dashGap;
      }
    }
    canvas.drawPath(dashPath, paint);
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

class _EmptyAlbumsState extends StatelessWidget {
  const _EmptyAlbumsState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: 36,
        vertical: 64,
      ),
      children: [
        Center(
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cubby.surfaceCard,
              borderRadius: CubbyRadius.xxlAll,
              border: Border.all(color: cubby.hairline, width: 1),
            ),
            child: Icon(
              Icons.folder_outlined,
              size: 36,
              color: scheme.primary,
            ),
          ),
        ),
        const SizedBox(height: CubbySpacing.lg),
        Text(
          '첫 앨범부터.',
          textAlign: TextAlign.center,
          style: CubbyType.displaySm.copyWith(
            fontSize: 22,
            letterSpacing: -0.2,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Cubby에서는 모든 촬영이\n앨범 안에서 시작됩니다.',
          textAlign: TextAlign.center,
          style: CubbyType.bodySm.copyWith(color: cubby.muted),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text.rich(
            TextSpan(
              style:
                  CubbyType.caption.copyWith(color: cubby.mutedSoft),
              children: [
                const TextSpan(text: '오른쪽 아래 '),
                TextSpan(
                  text: '＋',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const TextSpan(text: ' 버튼으로 시작하세요.'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _CubbyFab extends StatelessWidget {
  const _CubbyFab({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingActionButton.extended(
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white),
      label: Text(
        label,
        style: CubbyType.buttonLabel.copyWith(color: Colors.white),
      ),
      backgroundColor: scheme.primary,
      foregroundColor: Colors.white,
      elevation: 6,
      shape: const RoundedRectangleBorder(borderRadius: CubbyRadius.xlAll),
    );
  }
}


class _LimitedBanner extends StatelessWidget {
  const _LimitedBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        CubbySpacing.md,
        4,
        CubbySpacing.md,
        CubbySpacing.sm,
      ),
      padding: const EdgeInsets.all(CubbySpacing.md),
      decoration: BoxDecoration(
        color: cubby.surfaceCard,
        borderRadius: CubbyRadius.lgAll,
        border: Border.all(color: cubby.hairline, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: cubby.canvas,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.info_outline,
              size: 18,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: CubbySpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '선택한 사진만 보고 있어요',
                  style: CubbyType.titleSm.copyWith(
                    fontSize: 15,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '일부만 허용된 상태입니다. 더 많은 항목을 보려면 추가 선택을 해 주세요.',
                  style: CubbyType.caption.copyWith(
                    color: cubby.body,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: CubbySpacing.sm),
                TextButton(
                  onPressed: onTap,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.primary,
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('사진 더 선택'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CubbySpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 48, color: cubby.mutedSoft),
            const SizedBox(height: CubbySpacing.md),
            Text(
              '사진 라이브러리 접근이 꺼져 있어요',
              textAlign: TextAlign.center,
              style:
                  CubbyType.titleMd.copyWith(color: scheme.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              'Cubby가 앨범을 읽고 쓰려면 권한이 필요합니다.\n시스템 설정에서 다시 켜 주세요.',
              textAlign: TextAlign.center,
              style: CubbyType.bodySm.copyWith(color: cubby.body),
            ),
            const SizedBox(height: CubbySpacing.md),
            FilledButton(
              onPressed: onOpenSettings,
              style: FilledButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('설정 열기'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 한 줄짜리 텍스트의 실제 렌더링 높이를 [TextPainter]로 측정.
/// `maxLines: 1` ellipsis 텍스트와 동일 조건이라 `Text` 위젯이 차지할
/// 세로 픽셀과 일치한다. [_AlbumCard]의 셀 높이 계산이 폰트 변경/디바이스
/// 폰트 스케일에 자동으로 맞도록 사용.
double _measureTextHeight({
  required BuildContext context,
  required String sample,
  required TextStyle style,
}) {
  final mediaQuery = MediaQuery.of(context);
  final painter = TextPainter(
    text: TextSpan(text: sample, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaler: mediaQuery.textScaler,
  )..layout();
  return painter.size.height;
}

