import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

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
          return PhotoViewGalleryPageOptions.customChild(
            child: _AssetPage(asset: asset, future: _bytesFor(index)),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
          );
        },
      ),
    );
  }
}

class _AssetPage extends StatelessWidget {
  const _AssetPage({required this.asset, required this.future});

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
        final image = Image.memory(data, fit: BoxFit.contain);
        if (asset.type != AssetType.video) return image;
        return Stack(
          alignment: Alignment.center,
          children: [
            image,
            const Icon(
              Icons.play_circle_outline,
              color: Colors.white,
              size: 96,
            ),
          ],
        );
      },
    );
  }
}
