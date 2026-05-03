import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/media_asset.dart';
import '../../data/media_repository.dart';
import '../../data/photo_cache.dart';
import '../snackbar.dart';
import '../theme/cubby_tokens.dart';
import '../widgets/asset_thumbnail.dart';
import '../widgets/bordered_thumb.dart';

const int kGridThumbSize = 240;

const int _kPreviewThumbSize = 1080;
const int _kIndicatorThumbSize = 160;

// 디자인: 활성 56px, 비활성 38px. cell extent는 활성 셀이 들어갈 자리.
const double _kIndicatorCellExtent = 48;
const double _kIndicatorActiveSize = 56;
const double _kIndicatorInactiveSize = 38;
const double _kIndicatorStripHeight = 76;

Future<void> openMediaDetail(
  BuildContext context, {
  required List<MediaAsset> assets,
  required int initialIndex,
  required String albumId,
  required Map<String, Uint8List> seedThumbs,
  required ValueChanged<String> onAssetDeleted,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _MediaDetailPage(
        assets: assets,
        initialIndex: initialIndex,
        albumId: albumId,
        seedThumbs: seedThumbs,
        onAssetDeleted: onAssetDeleted,
      ),
    ),
  );
}

class _MediaDetailPage extends ConsumerStatefulWidget {
  const _MediaDetailPage({
    required this.assets,
    required this.initialIndex,
    required this.albumId,
    required this.seedThumbs,
    required this.onAssetDeleted,
  });

  final List<MediaAsset> assets;
  final int initialIndex;
  final String albumId;
  final Map<String, Uint8List> seedThumbs;
  final ValueChanged<String> onAssetDeleted;

  @override
  ConsumerState<_MediaDetailPage> createState() => _MediaDetailPageState();
}

class _MediaDetailPageState extends ConsumerState<_MediaDetailPage> {
  late final PageController _pageController;
  late final ScrollController _stripController;
  late List<MediaAsset> _assets;
  late int _currentIndex;

  VideoPlayerController? _activeVideoController;
  bool _zoomed = false;
  bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _assets = List.of(widget.assets);
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _stripController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _centerStripOn(widget.initialIndex, animate: false);
    });
  }

  @override
  void dispose() {
    // 페이지 떠날 때 시스템 UI 항상 복원 (immersive 상태로 빠져나가면 그리드가 가려짐).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController.dispose();
    _stripController.dispose();
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    SystemChrome.setEnabledSystemUIMode(
      _chromeVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _onActiveVideoControllerChanged(VideoPlayerController? c) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_activeVideoController == c) return;
      setState(() => _activeVideoController = c);
    });
  }

  void _onZoomChanged(bool zoomed) {
    if (_zoomed == zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
      _activeVideoController = null;
      _zoomed = false;
    });
    _centerStripOn(index);
  }

  void _jumpTo(int index) {
    _pageController.jumpToPage(index);
  }

  void _centerStripOn(int index, {bool animate = true}) {
    if (!_stripController.hasClients) return;
    final viewport = _stripController.position.viewportDimension;
    final target = index * _kIndicatorCellExtent +
        _kIndicatorCellExtent / 2 -
        viewport / 2;
    final clamped =
        target.clamp(0.0, _stripController.position.maxScrollExtent);
    if (animate) {
      _stripController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _stripController.jumpTo(clamped);
    }
  }

  Future<void> _share() async {
    final asset = _assets[_currentIndex];
    try {
      final file = await asset.originFile();
      if (file == null) {
        if (!mounted) return;
        showError(context, '공유 실패: 파일을 찾을 수 없습니다');
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } catch (e) {
      if (!mounted) return;
      showError(context, '공유 실패: $e');
    }
  }

  Future<void> _delete() async {
    final asset = _assets[_currentIndex];
    final repo = ref.read(mediaRepositoryProvider);
    try {
      final deletedIds = await repo.deleteAssets([asset]);
      if (!mounted) return;
      if (deletedIds.isEmpty) return; // user cancelled OS dialog
      widget.onAssetDeleted(asset.storageKey);
      _removeCurrentFromPager();
    } catch (e) {
      if (!mounted) return;
      showError(context, '삭제 실패: $e');
    }
  }

  void _removeCurrentFromPager() {
    if (_assets.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    final removedIndex = _currentIndex;
    setState(() {
      _assets.removeAt(removedIndex);
      // 마지막 인덱스를 지운 거라면 한 칸 앞으로.
      if (_currentIndex >= _assets.length) {
        _currentIndex = _assets.length - 1;
      }
      _activeVideoController = null;
      _zoomed = false;
    });
    // PageView가 사라진 인덱스를 가리키지 않도록 동기화.
    _pageController.jumpToPage(_currentIndex);
    _centerStripOn(_currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    final currentAsset = _assets[_currentIndex];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              // photo_view의 ScaleGestureRecognizer가 두 손가락 감지 시
              // gesture arena를 즉시 가져갈 수 있도록 axis를 명시. 이게 없으면
              // 부모 PageView의 HorizontalDragGestureRecognizer가 첫 핀치
              // 프레임을 가로채서 다음 페이지로 넘어간다 (flutter#68594).
              child: PhotoViewGestureDetectorScope(
                axis: Axis.horizontal,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _assets.length,
                  onPageChanged: _onPageChanged,
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemBuilder: (_, i) {
                    final asset = _assets[i];
                    if (asset.isVideo) {
                      return _VideoPage(
                        key: ValueKey('v_${asset.storageKey}'),
                        asset: asset,
                        isActive: i == _currentIndex,
                        onControllerChanged: i == _currentIndex
                            ? _onActiveVideoControllerChanged
                            : null,
                        onBackgroundTap: _toggleChrome,
                      );
                    }
                    return _PhotoPage(
                      key: ValueKey('p_${asset.storageKey}'),
                      asset: asset,
                      albumId: widget.albumId,
                      seedBytes: widget.seedThumbs[asset.storageKey],
                      onZoomChanged:
                          i == _currentIndex ? _onZoomChanged : null,
                      onTap: _toggleChrome,
                    );
                  },
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  opacity: _chromeVisible ? 1 : 0,
                  duration: CubbyMotion.immersive,
                  curve: CubbyMotion.immersiveCurve,
                  child: _TopChrome(
                    asset: currentAsset,
                    index: _currentIndex,
                    total: _assets.length,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  opacity: _chromeVisible ? 1 : 0,
                  duration: CubbyMotion.immersive,
                  curve: CubbyMotion.immersiveCurve,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_activeVideoController != null &&
                          currentAsset.isVideo)
                        _VideoControls(controller: _activeVideoController!),
                      _IndicatorStrip(
                        assets: _assets,
                        currentIndex: _currentIndex,
                        seedThumbs: widget.seedThumbs,
                        stripController: _stripController,
                        onTap: _jumpTo,
                      ),
                      SafeArea(
                        top: false,
                        child: _BottomActionBar(
                          onShare: _share,
                          onDelete: _delete,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.asset,
    required this.index,
    required this.total,
  });

  final MediaAsset asset;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final created = asset.createdAt;
    final dateLabel = _formatDateTime(created);
    return Container(
      padding: EdgeInsets.fromLTRB(
        4,
        topInset + 4,
        4,
        12,
      ),
      color: Colors.black.withValues(alpha: 0.34),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            tooltip: '돌아가기',
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  dateLabel,
                  style: CubbyType.titleSm.copyWith(
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${index + 1} / $total',
                  style: CubbyType.caption.copyWith(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  static String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final isToday = dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day;
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    if (isToday) return '오늘 $hh:$mm';
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return '어제 $hh:$mm';
    }
    return '${dt.month}월 ${dt.day}일 $hh:$mm';
  }
}

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({required this.onShare, required this.onDelete});

  final VoidCallback onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      color: Colors.black.withValues(alpha: 0.34),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _ViewerAction(
            icon: Icons.ios_share,
            label: '공유',
            onPressed: onShare,
          ),
          _ViewerAction(
            icon: Icons.delete_outline,
            label: '삭제',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _ViewerAction extends StatelessWidget {
  const _ViewerAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: CubbyType.caption.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoPage extends ConsumerStatefulWidget {
  const _PhotoPage({
    super.key,
    required this.asset,
    required this.albumId,
    required this.seedBytes,
    required this.onZoomChanged,
    required this.onTap,
  });

  final MediaAsset asset;
  final String albumId;
  final Uint8List? seedBytes;
  final ValueChanged<bool>? onZoomChanged;
  final VoidCallback onTap;

  @override
  ConsumerState<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends ConsumerState<_PhotoPage> {
  // Android: seedBytes(240) → previewBytes(1080) → file(원본).
  // iOS: seedBytes(240) → 원본 사이즈 thumbnail을 _previewBytes로 (HEIC 직접 디코딩 회피).
  Uint8List? _previewBytes;
  File? _file;

  // PhotoView가 내부 ScaleGestureRecognizer를 PageView보다 먼저 win하도록
  // arena를 처리해 줘서 InteractiveViewer + physics 토글의 race condition을
  // 우회한다. controller는 scale 변화 감지에만 사용.
  final _photoController = PhotoViewController();

  @override
  void initState() {
    super.initState();
    _photoController.outputStateStream.listen(_onPhotoState);
    _hydrateFromCache();
    if (Platform.isIOS) {
      if (_previewBytes == null) _loadIosOriginalAsBytes();
    } else {
      if (_previewBytes == null) _loadPreview();
      if (_file == null) _loadFile();
    }
  }

  @override
  void dispose() {
    _photoController.dispose();
    super.dispose();
  }

  void _hydrateFromCache() {
    final cache = ref.read(photoCacheProvider(widget.albumId));
    final entry = cache[widget.asset.storageKey];
    if (entry == null) return;
    _previewBytes = entry.previewBytes;
    _file = entry.file;
  }

  Future<void> _loadPreview() async {
    final bytes = await widget.asset.thumbnail(size: _kPreviewThumbSize);
    if (!mounted || bytes == null) return;
    ref
        .read(photoCacheProvider(widget.albumId).notifier)
        .update(widget.asset.storageKey, previewBytes: bytes);
    setState(() => _previewBytes = bytes);
  }

  Future<void> _loadFile() async {
    final file = await widget.asset.originFile();
    if (!mounted || file == null) return;
    ref
        .read(photoCacheProvider(widget.albumId).notifier)
        .update(widget.asset.storageKey, file: file);
    setState(() => _file = file);
  }

  Future<void> _loadIosOriginalAsBytes() async {
    // iOS HEIC는 직접 디코딩 불가. 원본 사이즈 thumbnail을 호출해 JPEG로
    // 받아 _previewBytes로 사용.
    final longSide = widget.asset.width > widget.asset.height
        ? widget.asset.width
        : widget.asset.height;
    final bytes = await widget.asset.thumbnail(size: longSide);
    if (!mounted || bytes == null) return;
    ref
        .read(photoCacheProvider(widget.albumId).notifier)
        .update(widget.asset.storageKey, previewBytes: bytes);
    setState(() => _previewBytes = bytes);
  }

  void _onPhotoState(PhotoViewControllerValue value) {
    // 부모(_MediaDetailPage._onZoomChanged)에 == 가드가 있어 같은 값은 무시된다.
    final zoomed = (value.scale ?? 1.0) > 1.001;
    widget.onZoomChanged?.call(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: PhotoView.customChild(
        controller: _photoController,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.contained * 4,
        initialScale: PhotoViewComputedScale.contained,
        basePosition: Alignment.center,
        child: _buildImage(),
      ),
    );
  }

  Widget _buildImage() {
    if (!Platform.isIOS && _file != null) {
      return Image.file(
        _file!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    if (_previewBytes != null) {
      return Image.memory(
        _previewBytes!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    if (widget.seedBytes != null) {
      return Image.memory(
        widget.seedBytes!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    return const SizedBox.shrink();
  }
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({
    super.key,
    required this.asset,
    required this.isActive,
    required this.onControllerChanged,
    required this.onBackgroundTap,
  });

  final MediaAsset asset;
  final bool isActive;
  final ValueChanged<VideoPlayerController?>? onControllerChanged;
  final VoidCallback onBackgroundTap;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  bool _setupStarted = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _setup();
  }

  @override
  void didUpdateWidget(_VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !_setupStarted) {
      _setup();
    } else if (!widget.isActive && _controller != null) {
      _controller?.pause();
    }
    if (widget.isActive &&
        oldWidget.isActive == false &&
        _controller != null &&
        _controller!.value.isInitialized) {
      widget.onControllerChanged?.call(_controller);
    }
  }

  Future<void> _setup() async {
    _setupStarted = true;
    final file = await widget.asset.originFile();
    if (!mounted || file == null) return;
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    if (widget.isActive) {
      widget.onControllerChanged?.call(controller);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    if (!ready) {
      return GestureDetector(
        onTap: widget.onBackgroundTap,
        behavior: HitTestBehavior.opaque,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    // 사진과 동일한 PhotoView 패턴으로 핀치 줌 + chrome 토글.
    // VideoPlayer는 Texture 위젯이라 PhotoView의 transform이 native layer에
    // 그대로 적용된다. controller가 chrome 토글을 그대로 받도록 onTapUp 사용.
    return PhotoView.customChild(
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.contained * 4,
      initialScale: PhotoViewComputedScale.contained,
      basePosition: Alignment.center,
      onTapUp: (_, __, ___) => widget.onBackgroundTap(),
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }
}

class _VideoControls extends StatelessWidget {
  const _VideoControls({required this.controller});

  final VideoPlayerController controller;

  void _togglePlay() {
    if (!controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return Container(
          color: Colors.black.withValues(alpha: 0.4),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(
                  value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: _togglePlay,
              ),
              Text(
                _format(value.position),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _format(value.duration),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(width: 8),
            ],
          ),
        );
      },
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _IndicatorStrip extends StatelessWidget {
  const _IndicatorStrip({
    required this.assets,
    required this.currentIndex,
    required this.seedThumbs,
    required this.stripController,
    required this.onTap,
  });

  final List<MediaAsset> assets;
  final int currentIndex;
  final Map<String, Uint8List> seedThumbs;
  final ScrollController stripController;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kIndicatorStripHeight,
      color: Colors.black.withValues(alpha: 0.34),
      alignment: Alignment.center,
      child: ListView.builder(
        controller: stripController,
        scrollDirection: Axis.horizontal,
        itemCount: assets.length,
        itemExtent: _kIndicatorCellExtent,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemBuilder: (_, i) {
          final asset = assets[i];
          final selected = i == currentIndex;
          final size =
              selected ? _kIndicatorActiveSize : _kIndicatorInactiveSize;
          final borderWidth = selected ? 2.0 : 1.0;
          return GestureDetector(
            onTap: () => onTap(i),
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: AnimatedSize(
                duration: CubbyMotion.immersive,
                curve: CubbyMotion.immersiveCurve,
                child: BorderedThumb(
                  size: size,
                  outerRadius: 8,
                  borderWidth: borderWidth,
                  borderColor: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.4),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AssetThumbnail(
                        asset: asset,
                        size: _kIndicatorThumbSize,
                        seedBytes: seedThumbs[asset.storageKey],
                        placeholder: Container(color: Colors.grey.shade800),
                      ),
                      if (asset.isVideo)
                        const Positioned(
                          top: 2,
                          right: 2,
                          child: Icon(
                            Icons.videocam,
                            color: Colors.white,
                            size: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

