import 'dart:io' show File;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// Size for the grid-cell thumbnail that's also reused as the Hero seed
/// for the detail flight. Both sides must match so Flutter's image cache
/// returns the same decoded bitmap.
const ThumbnailSize kGridThumbSize = ThumbnailSize.square(240);

/// Hero tag used to link a grid cell to its detail-route counterpart.
String photoHeroTag(String assetId) => 'photo_$assetId';

/// Push the full-screen photo detail. Returns once the user closes it.
///
/// [seedBytes] is the same 240px thumbnail data the grid is already
/// displaying. Passing it in lets the destination Hero render the exact
/// same pixels from frame 0 of the flight, which is what makes the
/// transition smooth — without this seed the destination Hero is empty
/// for ~200ms (the time it takes to re-fetch the thumbnail) and Flutter
/// effectively skips the flight.
Future<void> openPhotoDetail(
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
      pageBuilder: (_, animation, __) => _PhotoDetailPage(
        asset: asset,
        routeAnimation: animation,
        seedBytes: seedBytes,
      ),
      transitionsBuilder: (_, __, ___, child) => child,
    ),
  );
}

class _PhotoDetailPage extends StatefulWidget {
  const _PhotoDetailPage({
    required this.asset,
    required this.routeAnimation,
    required this.seedBytes,
  });

  final AssetEntity asset;
  final Animation<double> routeAnimation;
  final Uint8List seedBytes;

  @override
  State<_PhotoDetailPage> createState() => _PhotoDetailPageState();
}

class _PhotoDetailPageState extends State<_PhotoDetailPage> {
  // Drag-to-dismiss accumulator.
  double _dragOffset = 0;
  static const double _dismissThreshold = 120;
  static const double _opacityFadeRange = 240;

  // Pinch-zoom — drag-to-dismiss is disabled while zoomed in.
  final _viewer = TransformationController();
  bool _zoomed = false;

  // Progressive image stages, layered above the Hero — see build().
  static const _previewSize = ThumbnailSize.square(1080);
  Uint8List? _previewBytes;
  File? _file;

  @override
  void initState() {
    super.initState();
    _viewer.addListener(_onViewerChanged);
    _loadPreview();
    _loadFile();
  }

  @override
  void dispose() {
    _viewer.removeListener(_onViewerChanged);
    _viewer.dispose();
    super.dispose();
  }

  Future<void> _loadPreview() async {
    final bytes = await widget.asset.thumbnailDataWithSize(_previewSize);
    if (!mounted || bytes == null) return;
    setState(() => _previewBytes = bytes);
  }

  Future<void> _loadFile() async {
    final file = await widget.asset.file;
    if (!mounted || file == null) return;
    setState(() => _file = file);
  }

  void _onViewerChanged() {
    final zoomed = _viewer.value.row0.x > 1.001;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onVerticalDragUpdate(DragUpdateDetails d) {
    if (_zoomed) return;
    setState(() => _dragOffset += d.delta.dy);
  }

  void _onVerticalDragEnd(DragEndDetails d) {
    if (_zoomed) return;
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
    // Transparent Scaffold so the grid still bleeds through the dim
    // layer (we depend on opaque:false at the route level), while
    // giving descendant Text widgets a proper Material ancestor —
    // without one, debug builds draw yellow wavy underlines under
    // every Text on the page.
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
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            behavior: HitTestBehavior.translucent,
            child: Transform.translate(
              offset: Offset(0, _dragOffset),
              child: InteractiveViewer(
                transformationController: _viewer,
                minScale: 1.0,
                maxScale: 4.0,
                // Hero child stays a plain Image.memory(seedBytes) —
                // structurally identical to the grid cell so the flight
                // boundaries match. Higher-resolution stages are
                // *outside* the Hero, layered on top with Positioned.fill,
                // so the Hero overlay never has to interpolate between
                // tree shapes.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
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
                    if (_previewBytes != null)
                      Positioned.fill(
                        child: Image.memory(
                          _previewBytes!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                    if (_file != null)
                      Positioned.fill(
                        child: Image.file(
                          _file!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                  ],
                ),
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
