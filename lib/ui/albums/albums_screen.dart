import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../data/app_preferences.dart';
import '../../data/media_repository.dart';
import '../camera/camera_screen.dart';
import '../photos/photos_screen.dart';
import '../snackbar.dart';
import '../theme/cubby_theme.dart';
import '../theme/cubby_tokens.dart';
import '../widgets/cubby_mark.dart';
import 'new_album_sheet.dart';

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
      return _AlbumsLoadResult(
        permission: permission,
        albums: const [],
        coverAssets: const {},
      );
    }
    final albums = await repo.getUserAlbums();
    // 각 앨범의 가장 최근 자산 1장을 병렬로 가져온다 (placeholder/0개는 skip).
    final entries = await Future.wait(albums.map((a) async {
      if (a is PlaceholderAlbum || a.assetCount == 0) {
        return MapEntry(a.name, null as AssetEntity?);
      }
      try {
        final list = await repo.getAssets(a, page: 0, pageSize: 1);
        return MapEntry(a.name, list.isNotEmpty ? list.first : null);
      } catch (_) {
        return MapEntry(a.name, null as AssetEntity?);
      }
    }));
    return _AlbumsLoadResult(
      permission: permission,
      albums: albums,
      coverAssets: Map.fromEntries(entries),
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _showCreateSheet() async {
    final result = await showNewAlbumSheet(context);
    if (!mounted || result == null) return;
    try {
      final repo = ref.read(mediaRepositoryProvider);
      final album = await repo.createAlbum(result.name);
      if (!mounted) return;
      _reload();
      if (result.shootImmediately) {
        final saved = await Navigator.push<AssetEntity>(
          context,
          MaterialPageRoute(builder: (_) => CameraScreen(album: album)),
        );
        if (!mounted) return;
        if (saved != null) {
          // 카메라가 저장 직후 album이 placeholder였다면 시스템에 폴더가
          // materialise된 상태이므로 RealAlbum으로 promote 후 진입.
          // 그렇지 않으면 PhotosScreen이 placeholder 가드 때문에 빈 상태로
          // 시작해 첫 촬영물이 보이지 않는다.
          final resolved = await _resolveToReal(album.name) ?? album;
          if (!mounted) return;
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => PhotosScreen(album: resolved),
            ),
          );
          if (!mounted) return;
          _reload();
        }
      }
    } on DuplicateAlbumException {
      if (!mounted) return;
      showError(context, '이미 같은 이름의 앨범이 있습니다');
    } catch (e) {
      if (!mounted) return;
      showError(context, '앨범 생성 실패: $e');
    }
  }

  Future<RealAlbum?> _resolveToReal(String name) async {
    final albums = await ref.read(mediaRepositoryProvider).getUserAlbums();
    for (final a in albums.whereType<RealAlbum>()) {
      if (a.name == name) return a;
    }
    return null;
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<_AlbumsLoadResult>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _ErrorState(onRetry: _reload);
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final result = snapshot.data!;
            if (!result.permission.hasAccess) {
              return _PermissionDeniedView(onOpenSettings: _onOpenSettings);
            }
            return _AlbumsBody(
              result: result,
              onRefresh: () async => _reload(),
              onPresentLimited: _onPresentLimited,
            );
          },
        ),
      ),
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
    required this.result,
    required this.onRefresh,
    required this.onPresentLimited,
  });

  final _AlbumsLoadResult result;
  final Future<void> Function() onRefresh;
  final VoidCallback onPresentLimited;

  String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => '시스템 테마',
        ThemeMode.light => '라이트 모드',
        ThemeMode.dark => '다크 모드',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = result.albums;
    final isLimited = result.permission.isLimited;
    return Column(
      children: [
        _LargeAppBar(
          title: '앨범',
          subtitle: albums.isEmpty
              ? '아직 앨범이 없어요. 첫 앨범부터 시작해 보세요.'
              : '${albums.length}개',
          leading: const CubbyMark(size: 20),
          onTitleTap: () async {
            await ref.read(themeModeProvider.notifier).cycle();
            if (!context.mounted) return;
            final mode = ref.read(themeModeProvider);
            showInfo(context, _themeLabel(mode));
          },
        ),
        if (isLimited) _LimitedBanner(onTap: onPresentLimited),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: albums.isEmpty
                ? const _EmptyAlbumsState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      CubbySpacing.md,
                      4,
                      CubbySpacing.md,
                      120,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (_, i) {
                      final a = albums[i];
                      return _AlbumRow(
                        album: a,
                        cover: result.coverAssets[a.name],
                        isLast: i == albums.length - 1,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
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
          if (leading != null)
            Row(
              children: [
                leading!,
              ],
            ),
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

class _AlbumRow extends StatelessWidget {
  const _AlbumRow({
    required this.album,
    required this.cover,
    required this.isLast,
  });

  final AlbumDisplay album;
  final AssetEntity? cover;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    final isEmpty = album.assetCount == 0;
    return InkWell(
      onTap: () async {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => PhotosScreen(album: album)),
        );
        // refresh handled by parent didChangeDependencies via reload
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: isLast
            ? null
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: cubby.hairlineSoft, width: 1),
                ),
              ),
        child: Row(
          children: [
            _AlbumCover(empty: isEmpty, cover: cover),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: CubbyType.titleSm.copyWith(color: scheme.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isEmpty
                        ? '비어 있음 · 첫 촬영을 기다리는 중'
                        : '${album.assetCount}개',
                    style: CubbyType.caption.copyWith(color: cubby.muted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: cubby.mutedSoft),
          ],
        ),
      ),
    );
  }
}

class _AlbumCover extends StatelessWidget {
  const _AlbumCover({required this.empty, required this.cover});

  final bool empty;
  final AssetEntity? cover;

  @override
  Widget build(BuildContext context) {
    final cubby = context.cubby;
    if (empty) {
      return _DottedBorder(
        color: cubby.hairline,
        radius: CubbyRadius.lg,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: cubby.surfaceCard,
            borderRadius: CubbyRadius.lgAll,
          ),
          child: Icon(
            Icons.image_outlined,
            size: 22,
            color: cubby.mutedSoft,
          ),
        ),
      );
    }
    final asset = cover;
    if (asset == null) {
      return Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: cubby.surfaceCard,
          borderRadius: CubbyRadius.lgAll,
        ),
        child: Icon(
          Icons.photo_library_outlined,
          size: 22,
          color: cubby.muted,
        ),
      );
    }
    return ClipRRect(
      borderRadius: CubbyRadius.lgAll,
      child: SizedBox(
        width: 64,
        height: 64,
        child: _AlbumCoverThumbnail(asset: asset),
      ),
    );
  }
}

class _AlbumCoverThumbnail extends StatefulWidget {
  const _AlbumCoverThumbnail({required this.asset});

  final AssetEntity asset;

  @override
  State<_AlbumCoverThumbnail> createState() => _AlbumCoverThumbnailState();
}

class _AlbumCoverThumbnailState extends State<_AlbumCoverThumbnail> {
  static const _size = ThumbnailSize.square(160);
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(_AlbumCoverThumbnail old) {
    super.didUpdateWidget(old);
    if (old.asset.id != widget.asset.id) {
      _bytes = null;
      _fetch();
    }
  }

  Future<void> _fetch() async {
    final bytes = await widget.asset.thumbnailDataWithSize(_size);
    if (!mounted || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final cubby = context.cubby;
    final bytes = _bytes;
    if (bytes == null) {
      return Container(color: cubby.surfaceCard);
    }
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
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

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CubbySpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('앨범을 불러오지 못했습니다.', textAlign: TextAlign.center),
            const SizedBox(height: CubbySpacing.md),
            FilledButton(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ),
      ),
    );
  }
}

class _AlbumsLoadResult {
  const _AlbumsLoadResult({
    required this.permission,
    required this.albums,
    required this.coverAssets,
  });

  final PermissionState permission;
  final List<AlbumDisplay> albums;
  final Map<String, AssetEntity?> coverAssets;
}

