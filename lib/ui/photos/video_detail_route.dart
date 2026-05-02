import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

import 'photo_detail_route.dart' show photoHeroTag;

/// Push the full-screen video detail. Mirrors [openPhotoDetail]:
///
/// - [seedBytes] is the same first-frame thumbnail the grid is showing,
///   so the Hero flight has matching pixels on both ends.
/// - Once the route is at rest, an asynchronously-initialised
///   [VideoPlayer] is layered on top of the still frame; it stays
///   paused until the user taps it. We never put the VideoPlayer itself
///   in the Hero — initialising mid-flight races with the overlay
///   rebuild and produced a black flash in earlier prototypes.
Future<void> openVideoDetail(
  BuildContext context, {
  required AssetEntity asset,
  required Uint8List seedBytes,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (_, animation, __) => _VideoDetailPage(
        asset: asset,
        routeAnimation: animation,
        seedBytes: seedBytes,
      ),
      transitionsBuilder: (_, __, ___, child) => child,
    ),
  );
}

class _VideoDetailPage extends StatefulWidget {
  const _VideoDetailPage({
    required this.asset,
    required this.routeAnimation,
    required this.seedBytes,
  });

  final AssetEntity asset;
  final Animation<double> routeAnimation;
  final Uint8List seedBytes;

  @override
  State<_VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<_VideoDetailPage> {
  // Drag-to-dismiss state. No pinch-zoom for video — InteractiveViewer
  // would interfere with the tap-to-toggle gesture and the use-case
  // (zooming a video) is rare enough not to justify the complexity.
  double _dragOffset = 0;
  static const double _dismissThreshold = 120;
  static const double _opacityFadeRange = 240;

  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final file = await widget.asset.file;
    if (!mounted || file == null) return;
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    setState(() => _dragOffset += d.delta.dy);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_dragOffset.abs() > _dismissThreshold) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _dragOffset = 0);
  }

  double _dimOpacity(double routeT) {
    final dragT = (_dragOffset.abs() / _opacityFadeRange).clamp(0.0, 1.0);
    return routeT * (1 - dragT);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final isPlaying = ready && controller.value.isPlaying;
    // Transparent Scaffold for the same reason as photo_detail_route:
    // gives the controls' Text widgets a Material ancestor so they
    // don't render with debug yellow underlines.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
      children: [
        AnimatedBuilder(
          animation: widget.routeAnimation,
          builder: (_, __) => IgnorePointer(
            child: Opacity(
              opacity: _dimOpacity(widget.routeAnimation.value),
              child: const ColoredBox(
                color: Colors.black,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            onTap: _toggle,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            behavior: HitTestBehavior.opaque,
            child: Transform.translate(
              offset: Offset(0, _dragOffset),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The seed frame stays under everything — this is
                  // what the Hero flight lands on. Even after the
                  // video is initialised we keep it as the ground so
                  // the first paint is never empty.
                  Hero(
                    tag: photoHeroTag(widget.asset.id),
                    child: SizedBox.expand(
                      child: Image.memory(
                        widget.seedBytes,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                  if (ready)
                    Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                    ),
                  if (ready && !isPlaying)
                    const Center(
                      child: Icon(
                        Icons.play_circle_outline,
                        color: Colors.white,
                        size: 96,
                      ),
                    ),
                  if (ready)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SafeArea(
                        top: false,
                        child: _VideoControls(controller: controller),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          right: 8,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return Container(
          color: Colors.black.withValues(alpha: 0.4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
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
