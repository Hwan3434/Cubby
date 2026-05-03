import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/album.dart';
import '../../data/album_live.dart';
import '../../data/albums_catalog.dart';
import '../../data/media_asset.dart';
import '../../data/media_repository.dart';
import '../photos/media_detail_route.dart';
import '../snackbar.dart';
import '../theme/cubby_tokens.dart';
import '../widgets/bordered_thumb.dart';

enum _Mode { photo, video }

enum _Flash { off, auto, on }

extension on _Flash {
  _Flash next() => switch (this) {
        _Flash.off => _Flash.auto,
        _Flash.auto => _Flash.on,
        _Flash.on => _Flash.off,
      };

  IconData get icon => switch (this) {
        _Flash.off => Icons.flash_off,
        _Flash.auto => Icons.flash_auto,
        _Flash.on => Icons.flash_on,
      };

  FlashMode toFlashMode({required bool video}) {
    // 영상에선 always 모드가 보통 무시되므로 torch로 매핑.
    return switch (this) {
      _Flash.off => FlashMode.off,
      _Flash.auto => FlashMode.auto,
      _Flash.on => video ? FlashMode.torch : FlashMode.always,
    };
  }
}

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({
    super.key,
    required this.albumName,
    this.album,
  });

  /// 라우트의 진실 (`/albums/:name/camera`).
  final String albumName;

  /// 라우트 extra로 전달된 Album 힌트. 없으면 화면이 직접 lookup.
  final Album? album;

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {
  CameraController? _controller;
  String? _error;
  _Mode _mode = _Mode.photo;
  bool _busy = false;
  bool _recording = false;
  bool _switchingCamera = false;
  DateTime? _recordingStartedAt;
  Timer? _recordingTicker;
  Duration _recordedFor = Duration.zero;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  _Flash _flash = _Flash.off;

  // 좌하단 "최근 촬영" 썸네일 bytes. provider state는 자산만 제공하고
  // thumbnail은 여기서 한 번 fetch해 캐시한다 (provider 첫 자산이 바뀔 때마다
  // 다시 fetch).
  String? _recentAssetId;
  Uint8List? _recentBytes;

  // 이번 카메라 세션에서 저장에 성공한 자산 ID. close 시점에 PhotosScreen으로
  // 반환되어 "방금 찍은" 강조 표시에 사용. provider.addAsset로 이미 그리드에는
  // 동기화됐다.
  final List<String> _savedAssetIds = [];
  // 영상 녹화 중 빨간 사각형 heartbeat (750ms 1.0↔0.92 반복).
  AnimationController? _recordPulse;
  // 영상 모양 전환: 0=흰 원, 1=빨간 사각형. 셔터 누르면 forward/reverse.
  AnimationController? _recordMorph;
  // 사진 셔터: 흰 원이 1.0→0→1.0 (250ms 비대칭).
  AnimationController? _shutterPulse;
  // 사진 촬영 시 화면 전체 위 흰색 flash bleach (100ms 0→1→0).
  AnimationController? _flashFlash;

  // 핀치 줌 상태. _zoomMin/_zoomMax는 디바이스 한계, _zoomLevel은 현재 적용값.
  // _zoomBaseline은 onScaleStart 시점의 _zoomLevel을 보관해 update에서
  // baseline * scale로 새 값을 계산하는 데 사용.
  double _zoomMin = 1.0;
  double _zoomMax = 1.0;
  double _zoomLevel = 1.0;
  double _zoomBaseline = 1.0;
  bool _zoomVisible = false;
  Timer? _zoomHideTicker;
  // 핀치 update는 매 프레임 들어와 platform channel 호출이 백로그된다.
  // in-flight 가드로 한 번에 하나만 보내고, 마지막으로 요청된 값을 후속 호출로
  // 따라잡는다.
  bool _zoomInFlight = false;
  double? _zoomPending;

  @override
  void initState() {
    super.initState();
    _shutterPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _flashFlash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _recordPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    _recordMorph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _setup();
  }

  /// 저장 직전 album을 lookup. catalog에 이미 있으면 그쪽 사용해
  /// photo_manager round-trip을 피하고, cold start면 repository에 직접 묻는다.
  /// 어디서도 못 찾으면 placeholder를 만들어 saveImage가 mediaRoot/<name>/
  /// 경로를 새로 materialise하게 한다.
  Future<Album> _ensureAlbum() async {
    for (final a in ref.read(albumsCatalogProvider).albums) {
      if (a.name == widget.albumName) return a;
    }
    final albums = await ref.read(mediaRepositoryProvider).getUserAlbums();
    for (final a in albums) {
      if (a.name == widget.albumName) return a;
    }
    return Album(
      name: widget.albumName,
      origin: AlbumOrigin.placeholder,
      storedCount: 0,
    );
  }

  Future<void> _setup() async {
    // PhotosScreen이 이미 watch 중이면 첫 페이지 로드가 끝났을 가능성이
    // 크지만, 카메라가 다른 경로로 진입했거나 PhotosScreen이 로드 중인
    // 케이스를 대비해 loadMore를 한 번 트리거. provider가 같은 family라
    // PhotosScreen state를 깨뜨리지 않는다.
    Future.microtask(() {
      if (!mounted) return;
      ref.read(albumLiveProvider(widget.albumName).notifier).loadMore();
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _error = '사용 가능한 카메라가 없습니다');
        return;
      }
      _cameras = cameras;
      _cameraIndex = cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _bindCamera(cameras[_cameraIndex]);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '카메라를 열 수 없습니다: $e');
    }
  }

  Future<void> _onSavedAsset(MediaAsset asset) async {
    _savedAssetIds.add(asset.storageKey);
    // addAsset이 [albumLiveProvider]에 즉시 반영하고 그 안에서 catalog를
    // invalidate하므로 placeholder→system promote는 자연스럽게 반영된다.
    // 카메라 좌하단 썸네일은 build에서 provider.items.first를 watch하니
    // 새 자산이 떨어지면 자동으로 _ensureRecentBytes가 발사된다.
    ref.read(albumLiveProvider(widget.albumName).notifier).addAsset(asset);
  }

  Future<void> _openRecent(MediaAsset recent, List<MediaAsset> all) async {
    final initialIndex =
        all.indexWhere((a) => a.storageKey == recent.storageKey);
    await openMediaDetail(
      context,
      assets: List.unmodifiable(all),
      initialIndex: initialIndex < 0 ? 0 : initialIndex,
      albumId: widget.albumName,
      seedThumbs: _recentBytes != null && _recentAssetId == recent.id
          ? {recent.id: _recentBytes!}
          : const {},
      onAssetDeleted: (id) {
        if (!mounted) return;
        ref.read(albumLiveProvider(widget.albumName).notifier).removeAssets([id]);
      },
    );
  }

  /// 좌하단 표시할 가장 최근 자산의 썸네일을 fetch한다. 같은 ID면 skip.
  void _ensureRecentBytes(MediaAsset asset) {
    final key = asset.storageKey;
    if (_recentAssetId == key) return;
    _recentAssetId = key;
    () async {
      try {
        final bytes = await asset.thumbnail(size: 160);
        if (!mounted || _recentAssetId != key) return;
        setState(() => _recentBytes = bytes);
      } catch (_) {}
    }();
  }

  Future<void> _bindCamera(CameraDescription cam) async {
    final controller = CameraController(cam, ResolutionPreset.high);
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    // 새 controller에 현재 flash 모드 재적용 (실패해도 silently off로).
    await _applyFlashTo(controller, _flash);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    // 디바이스별 줌 범위 받기. 실패하면 1.0 고정.
    double zoomMin = 1.0;
    double zoomMax = 1.0;
    try {
      zoomMin = await controller.getMinZoomLevel();
      zoomMax = await controller.getMaxZoomLevel();
    } catch (_) {}
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _zoomMin = zoomMin;
      _zoomMax = zoomMax;
      _zoomLevel = zoomMin;
      _zoomBaseline = zoomMin;
    });
  }

  Future<void> _applyFlashTo(CameraController c, _Flash flash) async {
    try {
      await c.setFlashMode(flash.toFlashMode(video: _mode == _Mode.video));
    } catch (_) {
      // iOS 등 일부 모드 미지원 → off로 폴백.
      try {
        await c.setFlashMode(FlashMode.off);
      } catch (_) {}
      if (mounted) setState(() => _flash = _Flash.off);
    }
  }

  Future<void> _cycleFlash() async {
    final c = _controller;
    if (c == null || _busy) return;
    final next = _flash.next();
    setState(() => _flash = next);
    await _applyFlashTo(c, next);
  }

  void _onScaleStart(ScaleStartDetails _) {
    _zoomBaseline = _zoomLevel;
    _showZoom();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final c = _controller;
    if (c == null || _zoomMax <= _zoomMin) return;
    final next = (_zoomBaseline * d.scale).clamp(_zoomMin, _zoomMax);
    if ((next - _zoomLevel).abs() < 0.01) return;
    setState(() => _zoomLevel = next);
    _showZoom();
    _requestZoom(c, next);
  }

  void _requestZoom(CameraController c, double level) {
    if (_zoomInFlight) {
      _zoomPending = level;
      return;
    }
    _zoomInFlight = true;
    () async {
      try {
        await c.setZoomLevel(level);
      } catch (_) {}
      if (!mounted) {
        _zoomInFlight = false;
        return;
      }
      _zoomInFlight = false;
      final pending = _zoomPending;
      if (pending != null && pending != level) {
        _zoomPending = null;
        _requestZoom(c, pending);
      }
    }();
  }

  void _onScaleEnd(ScaleEndDetails _) {
    _scheduleZoomHide();
  }

  void _showZoom() {
    _zoomHideTicker?.cancel();
    if (!_zoomVisible) {
      setState(() => _zoomVisible = true);
    }
  }

  void _scheduleZoomHide() {
    _zoomHideTicker?.cancel();
    _zoomHideTicker = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _zoomVisible = false);
    });
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2 || _switchingCamera || _recording || _busy) return;
    setState(() => _switchingCamera = true);
    try {
      await _controller?.dispose();
      _controller = null;
      _cameraIndex = (_cameraIndex + 1) % _cameras.length;
      await _bindCamera(_cameras[_cameraIndex]);
    } catch (e) {
      if (!mounted) return;
      showError(context, '카메라 전환 실패: $e');
    } finally {
      if (mounted) setState(() => _switchingCamera = false);
    }
  }

  @override
  void dispose() {
    _recordingTicker?.cancel();
    _zoomHideTicker?.cancel();
    _shutterPulse?.dispose();
    _flashFlash?.dispose();
    _recordPulse?.dispose();
    _recordMorph?.dispose();
    final c = _controller;
    _controller = null;
    c?.dispose();
    super.dispose();
  }

  Future<void> _capturePhoto() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    _shutterPulse?.forward(from: 0);
    _flashFlash?.forward(from: 0);
    setState(() => _busy = true);
    try {
      final xfile = await controller.takePicture();
      final bytes = await xfile.readAsBytes();
      if (!mounted) return;
      final repo = ref.read(mediaRepositoryProvider);
      final album = await _ensureAlbum();
      if (!mounted) return;
      final asset = await repo.saveImage(
        bytes: bytes,
        filename: 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
        album: album,
      );
      if (!mounted) return;
      await _onSavedAsset(asset);
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showError(context, '촬영 실패: $e');
    }
  }

  Future<void> _toggleRecording() async {
    final controller = _controller;
    if (controller == null || _busy) return;

    if (!_recording) {
      try {
        await controller.startVideoRecording();
        if (!mounted) return;
        setState(() {
          _recording = true;
          _recordingStartedAt = DateTime.now();
          _recordedFor = Duration.zero;
        });
        _recordMorph?.forward();
        _recordPulse?.repeat(reverse: true);
        _recordingTicker = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) {
            final start = _recordingStartedAt;
            if (!mounted || start == null) return;
            setState(() => _recordedFor = DateTime.now().difference(start));
          },
        );
      } catch (e) {
        if (!mounted) return;
        showError(context, '녹화 시작 실패: $e');
      }
      return;
    }

    setState(() => _busy = true);
    _recordingTicker?.cancel();
    _recordPulse?.stop();
    _recordPulse?.reset();
    _recordMorph?.reverse();
    try {
      final xfile = await controller.stopVideoRecording();
      if (!mounted) return;
      final repo = ref.read(mediaRepositoryProvider);
      final album = await _ensureAlbum();
      if (!mounted) return;
      final asset = await repo.saveVideo(
        file: File(xfile.path),
        filename: 'VID_${DateTime.now().millisecondsSinceEpoch}.mp4',
        album: album,
      );
      if (!mounted) return;
      await _onSavedAsset(asset);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _recording = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _recording = false;
      });
      showError(context, '저장 실패: $e');
    }
  }

  Future<void> _setMode(_Mode mode) async {
    if (_recording || _busy) return;
    setState(() => _mode = mode);
    final c = _controller;
    if (c != null) {
      await _applyFlashTo(c, _flash);
    }
  }

  Future<void> _onPopAttemptedWhileRecording() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('녹화 중'),
        content: const Text('나가면 녹화가 저장되지 않습니다. 중단할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속 녹화'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('중단'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      _recordingTicker?.cancel();
      await _controller?.stopVideoRecording();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _recording = false);
    context.pop(_savedAssetIds);
  }

  void _close() {
    context.pop(_savedAssetIds);
  }

  @override
  Widget build(BuildContext context) {
    // 시스템 back과 close 버튼 모두 같은 경로로 pop(_savedAssetIds)을
    // 보내야 PhotosScreen이 fresh ID와 공유 다이얼로그를 처리할 수 있다.
    // canPop: false로 둬서 시스템 back을 무조건 가로채고, 녹화 중이 아니면
    // _close()로 위임.
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_recording) {
          _onPopAttemptedWhileRecording();
          return;
        }
        _close();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    final assetsState = ref.watch(albumLiveProvider(widget.albumName));
    final recentAsset =
        assetsState.items.isNotEmpty ? assetsState.items.first : null;
    if (recentAsset != null) {
      _ensureRecentBytes(recentAsset);
    } else if (_recentAssetId != null) {
      _recentAssetId = null;
      _recentBytes = null;
    }
    final preview = controller.value.previewSize;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: ClipRect(
              child: preview == null
                  ? CameraPreview(controller)
                  : FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        // previewSize는 sensor 좌표계라 폰을 세로로 들면
                        // width/height가 뒤집혀 들어옴. cover 트릭은 표준 패턴.
                        width: preview.height,
                        height: preview.width,
                        child: CameraPreview(controller),
                      ),
                    ),
            ),
          ),
        ),
        const Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _RuleOfThirdsPainter()),
          ),
        ),
        if (_zoomMax > _zoomMin)
          Positioned(
            left: 0,
            right: 0,
            bottom: 220,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _zoomVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Center(
                  child: _ZoomChip(level: _zoomLevel),
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: SafeArea(
            child: _CameraTopBar(
              albumName: widget.albumName,
              flash: _flash,
              onCycleFlash: _cycleFlash,
              onClose: _close,
            ),
          ),
        ),
        if (_recording)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 56,
            left: 0,
            right: 0,
            child: Center(
              child: _RecordingChip(elapsed: _recordedFor),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 110),
              child: Center(
                child: _ModeSwitcher(
                  mode: _mode,
                  enabled: !_recording && !_busy,
                  onChanged: _setMode,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
              child: SizedBox(
                height: 78,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _RecentThumb(
                        bytes: _recentBytes,
                        onTap: recentAsset == null
                            ? null
                            : () =>
                                _openRecent(recentAsset, assetsState.items),
                      ),
                    ),
                    _ShutterButton(
                      mode: _mode,
                      busy: _busy,
                      recording: _recording,
                      shutterPulse: _shutterPulse,
                      recordPulse: _recordPulse,
                      recordMorph: _recordMorph,
                      onTap: _mode == _Mode.photo
                          ? _capturePhoto
                          : _toggleRecording,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _IconAction(
                        icon: Icons.cameraswitch_outlined,
                        onPressed: _cameras.length < 2 ||
                                _switchingCamera ||
                                _recording ||
                                _busy
                            ? null
                            : _flipCamera,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_flashFlash != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flashFlash!,
                builder: (_, __) {
                  // 0→1 진행에서 alpha를 0→1→0 (삼각파)으로.
                  final v = _flashFlash!.value;
                  final triangle = v < 0.5 ? v * 2 : (1 - v) * 2;
                  return ColoredBox(
                    color: Colors.white.withValues(alpha: triangle * 0.6),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _CameraTopBar extends StatelessWidget {
  const _CameraTopBar({
    required this.albumName,
    required this.flash,
    required this.onCycleFlash,
    required this.onClose,
  });

  final String albumName;
  final _Flash flash;
  final VoidCallback onCycleFlash;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  '저장 위치',
                  style: CubbyType.captionUpper.copyWith(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.65),
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(9999),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.folder_outlined,
                        size: 13,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        albumName,
                        style: CubbyType.titleSm.copyWith(
                          fontSize: 13,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _IconAction(icon: flash.icon, onPressed: onCycleFlash),
        ],
      ),
    );
  }
}

class _RecordingChip extends StatelessWidget {
  const _RecordingChip({required this.elapsed});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final mm = elapsed.inMinutes.toString().padLeft(1, '0');
    final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
      decoration: BoxDecoration(
        color: const Color(0xFFC64545).withValues(alpha: 0.92),
        borderRadius: const BorderRadius.all(Radius.circular(9999)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _BlinkingDot(),
          const SizedBox(width: 8),
          Text(
            '녹화 중 · $mm:$ss',
            style: CubbyType.titleSm.copyWith(
              fontSize: 13,
              color: Colors.white,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _BlinkingDot extends StatefulWidget {
  const _BlinkingDot();

  @override
  State<_BlinkingDot> createState() => _BlinkingDotState();
}

class _BlinkingDotState extends State<_BlinkingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.4, end: 1.0).animate(_ctl),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _ModeSwitcher extends StatelessWidget {
  const _ModeSwitcher({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final _Mode mode;
  final bool enabled;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeChip(
            label: '사진',
            active: mode == _Mode.photo,
            onTap: enabled ? () => onChanged(_Mode.photo) : null,
          ),
          const SizedBox(width: 18),
          _ModeChip(
            label: '영상',
            active: mode == _Mode.video,
            onTap: enabled ? () => onChanged(_Mode.video) : null,
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xEAFAF9F5)
              : Colors.transparent,
          border: active
              ? null
              : Border.all(color: Colors.white.withValues(alpha: 0.4)),
          borderRadius: const BorderRadius.all(Radius.circular(9999)),
        ),
        child: Text(
          label,
          style: CubbyType.titleSm.copyWith(
            fontSize: 13,
            color: active
                ? const Color(0xFF141413)
                : Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.mode,
    required this.busy,
    required this.recording,
    required this.shutterPulse,
    required this.recordPulse,
    required this.recordMorph,
    required this.onTap,
  });

  final _Mode mode;
  final bool busy;
  final bool recording;
  final AnimationController? shutterPulse;
  final AnimationController? recordPulse;
  final AnimationController? recordMorph;
  final VoidCallback onTap;

  static const _circleSize = 62.0;
  static const _squareSize = 30.0;
  static const _circleRadius = _circleSize / 2;
  static const _squareRadius = 6.0;
  static const _white = Color(0xFFFAF9F5);
  static const _red = Color(0xFFC64545);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _white, width: 4),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: Listenable.merge(
              [shutterPulse, recordPulse, recordMorph],
            ),
            builder: (context, _) {
              // 영상 morph: 0=흰 원, 1=빨간 사각형. 셔터 누름에 따라
              // forward/reverse가 직접 driving.
              final morph = recordMorph?.value ?? 0.0;
              // 사진 셔터: 0→0.5 사이엔 흰 원이 사라지고, 0.5→1 사이엔 복귀.
              // 영상 morph 중엔 적용 안 함.
              double scale = 1.0;
              if (morph < 0.001 && shutterPulse != null) {
                final v = shutterPulse!.value;
                if (v > 0) {
                  scale = v < 0.5 ? 1.0 - (v * 2) : (v - 0.5) * 2;
                }
              }
              // 영상 녹화 중 heartbeat: 1.0 → 0.92 부드럽게 반복.
              if (recording && recordPulse != null) {
                scale = scale * (1.0 - 0.08 * recordPulse!.value);
              }
              final size = _lerp(_circleSize, _squareSize, morph);
              final radius = _lerp(_circleRadius, _squareRadius, morph);
              final color = Color.lerp(_white, _red, morph)!;
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(radius),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

class _RecentThumb extends StatelessWidget {
  const _RecentThumb({required this.bytes, required this.onTap});

  final Uint8List? bytes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = bytes != null;
    return GestureDetector(
      onTap: onTap,
      child: BorderedThumb(
        size: 50,
        outerRadius: 12,
        borderWidth: 2,
        borderColor: Colors.white.withValues(alpha: 0.7),
        fillColor: Colors.white.withValues(alpha: 0.08),
        child: hasImage
            ? Image.memory(bytes!, fit: BoxFit.cover, gaplessPlayback: true)
            : Center(
                child: Icon(
                  Icons.image_outlined,
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
      ),
    );
  }
}

class _ZoomChip extends StatelessWidget {
  const _ZoomChip({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final text = level >= 10
        ? '${level.round()}x'
        : '${level.toStringAsFixed(1)}x';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: const BorderRadius.all(Radius.circular(9999)),
      ),
      child: Text(
        text,
        style: CubbyType.titleSm.copyWith(
          fontSize: 13,
          color: Colors.white,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        icon: Icon(
          icon,
          color: Colors.white.withValues(alpha: disabled ? 0.35 : 0.9),
          size: 22,
        ),
      ),
    );
  }
}

class _RuleOfThirdsPainter extends CustomPainter {
  const _RuleOfThirdsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    canvas.drawLine(Offset(w / 3, 0), Offset(w / 3, h), paint);
    canvas.drawLine(Offset(2 * w / 3, 0), Offset(2 * w / 3, h), paint);
    canvas.drawLine(Offset(0, h / 3), Offset(w, h / 3), paint);
    canvas.drawLine(Offset(0, 2 * h / 3), Offset(w, 2 * h / 3), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
