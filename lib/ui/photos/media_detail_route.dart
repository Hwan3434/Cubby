import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/media_repository.dart';
import '../../data/photo_cache.dart';
import '../snackbar.dart';

const ThumbnailSize kGridThumbSize = ThumbnailSize.square(240);

const ThumbnailSize _kPreviewThumbSize = ThumbnailSize.square(1080);
const ThumbnailSize _kIndicatorThumbSize = ThumbnailSize.square(160);
const double _kIndicatorCellSize = 56;
const double _kIndicatorActiveCellSize = 64;
const double _kIndicatorStripHeight = 88;

Future<void> openMediaDetail(
  BuildContext context, {
  required List<AssetEntity> assets,
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

  final List<AssetEntity> assets;
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
  late List<AssetEntity> _assets;
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
    final target = index * _kIndicatorCellSize +
        _kIndicatorCellSize / 2 -
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
      final file = await asset.file;
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
      widget.onAssetDeleted(asset.id);
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
              child: PageView.builder(
                controller: _pageController,
                itemCount: _assets.length,
                onPageChanged: _onPageChanged,
                physics: _zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemBuilder: (_, i) {
                  final asset = _assets[i];
                  if (asset.type == AssetType.video) {
                    return _VideoPage(
                      key: ValueKey('v_${asset.id}'),
                      asset: asset,
                      isActive: i == _currentIndex,
                      onControllerChanged: i == _currentIndex
                          ? _onActiveVideoControllerChanged
                          : null,
                      onBackgroundTap: _toggleChrome,
                    );
                  }
                  return _PhotoPage(
                    key: ValueKey('p_${asset.id}'),
                    asset: asset,
                    albumId: widget.albumId,
                    seedBytes: widget.seedThumbs[asset.id],
                    onZoomChanged: i == _currentIndex ? _onZoomChanged : null,
                    onTap: _toggleChrome,
                  );
                },
              ),
            ),
            Positioned(
              top: MediaQuery.paddingOf(context).top + 8,
              right: 8,
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: AnimatedOpacity(
                  opacity: _chromeVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _OverlayIconButton(
                        icon: Icons.share,
                        onPressed: _share,
                      ),
                      const SizedBox(width: 4),
                      _OverlayIconButton(
                        icon: Icons.delete_outline,
                        onPressed: _delete,
                      ),
                    ],
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
                  duration: const Duration(milliseconds: 150),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_activeVideoController != null &&
                            currentAsset.type == AssetType.video)
                          _VideoControls(controller: _activeVideoController!),
                        _IndicatorStrip(
                          assets: _assets,
                          currentIndex: _currentIndex,
                          seedThumbs: widget.seedThumbs,
                          stripController: _stripController,
                          onTap: _jumpTo,
                        ),
                      ],
                    ),
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

class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
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

  final AssetEntity asset;
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

  final _viewer = TransformationController();

  @override
  void initState() {
    super.initState();
    _viewer.addListener(_onViewerChanged);
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
    _viewer.removeListener(_onViewerChanged);
    _viewer.dispose();
    super.dispose();
  }

  void _hydrateFromCache() {
    final cache = ref.read(photoCacheProvider(widget.albumId));
    final entry = cache[widget.asset.id];
    if (entry == null) return;
    _previewBytes = entry.previewBytes;
    _file = entry.file;
  }

  Future<void> _loadPreview() async {
    final bytes = await widget.asset.thumbnailDataWithSize(_kPreviewThumbSize);
    if (!mounted || bytes == null) return;
    ref
        .read(photoCacheProvider(widget.albumId).notifier)
        .update(widget.asset.id, previewBytes: bytes);
    setState(() => _previewBytes = bytes);
  }

  Future<void> _loadFile() async {
    final file = await widget.asset.file;
    if (!mounted || file == null) return;
    ref
        .read(photoCacheProvider(widget.albumId).notifier)
        .update(widget.asset.id, file: file);
    setState(() => _file = file);
  }

  Future<void> _loadIosOriginalAsBytes() async {
    // iOS는 HEIC 직접 디코딩 회피 — 원본 사이즈 thumbnail로 대체.
    final size = ThumbnailSize(widget.asset.width, widget.asset.height);
    final bytes = await widget.asset.thumbnailDataWithSize(size);
    if (!mounted || bytes == null) return;
    ref
        .read(photoCacheProvider(widget.albumId).notifier)
        .update(widget.asset.id, previewBytes: bytes);
    setState(() => _previewBytes = bytes);
  }

  void _onViewerChanged() {
    // 부모(_MediaDetailPage._onZoomChanged)에 == 가드가 있어 같은 값은 무시된다.
    final zoomed = _viewer.value.row0.x > 1.001;
    widget.onZoomChanged?.call(zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: InteractiveViewer(
        transformationController: _viewer,
        minScale: 1.0,
        maxScale: 4.0,
        child: SizedBox.expand(
          child: Center(child: _buildImage()),
        ),
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

  final AssetEntity asset;
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
    final file = await widget.asset.file;
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
    return GestureDetector(
      onTap: widget.onBackgroundTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!ready)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          if (ready)
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
        ],
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

  final List<AssetEntity> assets;
  final int currentIndex;
  final Map<String, Uint8List> seedThumbs;
  final ScrollController stripController;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kIndicatorStripHeight,
      color: Colors.black.withValues(alpha: 0.4),
      alignment: Alignment.center,
      child: ListView.builder(
        controller: stripController,
        scrollDirection: Axis.horizontal,
        itemCount: assets.length,
        itemExtent: _kIndicatorCellSize,
        padding: EdgeInsets.zero,
        itemBuilder: (_, i) {
          final asset = assets[i];
          final selected = i == currentIndex;
          return GestureDetector(
            onTap: () => onTap(i),
            behavior: HitTestBehavior.opaque,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: selected
                    ? _kIndicatorActiveCellSize
                    : _kIndicatorCellSize - 8,
                height: selected
                    ? _kIndicatorActiveCellSize
                    : _kIndicatorCellSize - 8,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selected ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: _IndicatorThumb(
                  asset: asset,
                  seed: seedThumbs[asset.id],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IndicatorThumb extends StatefulWidget {
  const _IndicatorThumb({required this.asset, required this.seed});

  final AssetEntity asset;
  final Uint8List? seed;

  @override
  State<_IndicatorThumb> createState() => _IndicatorThumbState();
}

class _IndicatorThumbState extends State<_IndicatorThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.seed;
    if (_bytes == null) _fetch();
  }

  Future<void> _fetch() async {
    final bytes =
        await widget.asset.thumbnailDataWithSize(_kIndicatorThumbSize);
    if (!mounted || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes == null)
          Container(color: Colors.grey.shade800)
        else
          Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        if (widget.asset.type == AssetType.video)
          const Positioned(
            top: 2,
            right: 2,
            child: Icon(Icons.videocam, color: Colors.white, size: 12),
          ),
      ],
    );
  }
}
