import 'dart:io' show File;
import 'dart:typed_data';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'photo_cache.g.dart';

/// In-memory cache of resolved bytes/files for assets, scoped per album.
///
/// Three resolution stages live on the same record so the detail route
/// can pick the highest-quality source available without a separate
/// fetch:
///
///   - thumbBytes: 240px JPEG, the same picker the grid uses. Acts as
///     the Hero seed.
///   - previewBytes: 1080px JPEG, full-screen-quality.
///   - file: the original asset on disk, for pinch-zoom.
class ResolvedPhoto {
  const ResolvedPhoto({this.thumbBytes, this.previewBytes, this.file});

  final Uint8List? thumbBytes;
  final Uint8List? previewBytes;
  final File? file;

  ResolvedPhoto copyWith({
    Uint8List? thumbBytes,
    Uint8List? previewBytes,
    File? file,
  }) {
    return ResolvedPhoto(
      thumbBytes: thumbBytes ?? this.thumbBytes,
      previewBytes: previewBytes ?? this.previewBytes,
      file: file ?? this.file,
    );
  }
}

/// Provider family keyed by album id. Each album gets its own
/// `Map<assetId, ResolvedPhoto>`; moving to another album leaves this
/// one untouched, and Riverpod can reclaim it once nothing watches.
@riverpod
class PhotoCache extends _$PhotoCache {
  @override
  Map<String, ResolvedPhoto> build(String albumId) => const {};

  /// Merge new fields onto the entry for [assetId]. Pass only the
  /// stages you just resolved; missing fields keep their previous
  /// values.
  void update(
    String assetId, {
    Uint8List? thumbBytes,
    Uint8List? previewBytes,
    File? file,
  }) {
    final existing = state[assetId] ?? const ResolvedPhoto();
    state = {
      ...state,
      assetId: existing.copyWith(
        thumbBytes: thumbBytes,
        previewBytes: previewBytes,
        file: file,
      ),
    };
  }
}
