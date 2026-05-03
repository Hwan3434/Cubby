import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/media_asset.dart';

/// [MediaAsset]의 썸네일을 비동기로 받아 표시하는 작은 위젯. 셀이 [asset]을
/// 바꾸면 자동으로 다시 fetch. 호출처마다 같은 패턴(initState/didUpdateWidget
/// /Image.memory fallback)을 새로 짜지 않도록 한 곳에 모음.
///
/// - [size]: 정사각 썸네일 한 변(px). photo_manager가 받는 [ThumbnailSize].
/// - [seedBytes]: 부모가 미리 fetch한 작은 썸네일을 첫 프레임으로 보여주고
///   싶을 때. detail route의 strip 등 hot-handoff에 쓰임.
/// - [onBytesLoaded]: fetch 성공 시 부모가 키-바이트 캐시를 채우고 싶을 때.
/// - [placeholder]: bytes가 아직 없을 때 깔리는 위젯. 기본은 회색 캔버스.
class AssetThumbnail extends StatefulWidget {
  const AssetThumbnail({
    super.key,
    required this.asset,
    this.size = 240,
    this.seedBytes,
    this.onBytesLoaded,
    this.placeholder,
  });

  final MediaAsset asset;
  final int size;
  final Uint8List? seedBytes;
  final void Function(String storageKey, Uint8List bytes)? onBytesLoaded;
  final Widget? placeholder;

  @override
  State<AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<AssetThumbnail> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.seedBytes;
    if (_bytes == null) _fetch();
  }

  @override
  void didUpdateWidget(AssetThumbnail old) {
    super.didUpdateWidget(old);
    if (old.asset.storageKey != widget.asset.storageKey) {
      _bytes = widget.seedBytes;
      if (_bytes == null) _fetch();
    }
  }

  Future<void> _fetch() async {
    final key = widget.asset.storageKey;
    final bytes = await widget.asset.thumbnail(size: widget.size);
    if (!mounted || bytes == null) return;
    if (widget.asset.storageKey != key) return;
    widget.onBytesLoaded?.call(key, bytes);
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return widget.placeholder ?? const ColoredBox(color: Color(0x11000000));
    }
    return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }
}
