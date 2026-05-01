import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:video_player/video_player.dart';

class PhotoDetailScreen extends StatefulWidget {
  const PhotoDetailScreen({
    super.key,
    required this.assets,
    required this.initialIndex,
  });

  final List<AssetEntity> assets;
  final int initialIndex;

  @override
  State<PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends State<PhotoDetailScreen> {
  late int _index;
  late final PageController _controller;
  // 1920px JPEG thumbs render reliably on both platforms (avoids HEIC
  // decode issues on iOS) and look acceptable when zoomed.
  static const _thumbSize = ThumbnailSize(1920, 1920);
  final Map<int, Future<Uint8List?>> _futures = {};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<Uint8List?> _bytesFor(int index) {
    return _futures.putIfAbsent(
      index,
      () => widget.assets[index].thumbnailDataWithSize(_thumbSize),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.assets.length}'),
      ),
      body: PhotoViewGallery.builder(
        itemCount: widget.assets.length,
        pageController: _controller,
        onPageChanged: (i) => setState(() => _index = i),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, __) =>
            const Center(child: CircularProgressIndicator()),
        builder: (context, index) {
          final asset = widget.assets[index];
          if (asset.type == AssetType.video) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _VideoPage(asset: asset),
              // disable zoom on video pages
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.contained,
            );
          }
          return PhotoViewGalleryPageOptions.customChild(
            child: _ImagePage(asset: asset, future: _bytesFor(index)),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
          );
        },
      ),
    );
  }
}

class _ImagePage extends StatelessWidget {
  const _ImagePage({required this.asset, required this.future});

  final AssetEntity asset;
  final Future<Uint8List?> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data;
        if (data == null) {
          return const Center(
            child: Icon(Icons.broken_image, color: Colors.white, size: 48),
          );
        }
        return Image.memory(data, fit: BoxFit.contain);
      },
    );
  }
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.asset});

  final AssetEntity asset;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final file = await widget.asset.file;
      if (file == null) {
        if (!mounted) return;
        setState(() => _error = '영상을 불러오지 못했습니다');
        return;
      }
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '영상을 불러오지 못했습니다: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
      } else {
        c.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return GestureDetector(
      onTap: _toggle,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              ),
              if (!value.isPlaying)
                const Icon(
                  Icons.play_circle_outline,
                  color: Colors.white,
                  size: 96,
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Text(
                        _formatDuration(value.position),
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
                        _formatDuration(value.duration),
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
