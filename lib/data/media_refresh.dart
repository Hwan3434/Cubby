import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 외부 카메라가 raw file로만 떨궈둔 자산을 MediaProvider에 commit. 같은
/// 프로세스 binder cache invalidation은 [MainActivity]의 ContentObserver가
/// 처리. iOS는 no-op.
Future<void> scanCameraDirs() async {
  if (!Platform.isAndroid) return;
  const channel = MethodChannel('cubby/media_refresh');
  try {
    await channel.invokeMethod<void>('scanCamera');
  } on PlatformException catch (e) {
    debugPrint('[mediaRefresh] scanCamera platform error: $e');
  } catch (e) {
    debugPrint('[mediaRefresh] scanCamera error: $e');
  }
}

/// [bucket]의 최근 자산 [limit]개를 image+video 통합으로. photo_manager 누락
/// 함정의 그리드/cover 보강용. 각 항목은 file path까지 가져 detail/share가
/// 진짜 파일을 디코딩할 수 있다.
Future<List<NativeRecent>> fetchRecentByBucket(
  String bucket, {
  int limit = 8,
  int size = 200,
}) async {
  if (!Platform.isAndroid) return const [];
  const channel = MethodChannel('cubby/media_refresh');
  try {
    final dynamic res = await channel.invokeMethod<dynamic>(
      'recentByBucket',
      {'bucket': bucket, 'limit': limit, 'size': size},
    );
    if (res is! List) return const [];
    final out = <NativeRecent>[];
    for (final entry in res) {
      if (entry is! Map) continue;
      final bytes = entry['bytes'];
      if (bytes is! Uint8List) continue;
      final id = (entry['id'] as num?)?.toInt() ?? 0;
      final isVideo = (entry['isVideo'] as bool?) ?? false;
      final dateTaken = (entry['dateTaken'] as num?)?.toInt() ?? 0;
      final dateAdded = (entry['dateAdded'] as num?)?.toInt() ?? 0;
      final data = entry['data'] as String?;
      out.add(
        NativeRecent(
          id: id,
          isVideo: isVideo,
          bytes: bytes,
          dateTaken: dateTaken,
          dateAdded: dateAdded,
          data: data,
        ),
      );
    }
    return out;
  } on PlatformException catch (e) {
    debugPrint('[mediaRefresh] recentByBucket($bucket) error: $e');
    return const [];
  } catch (e) {
    debugPrint('[mediaRefresh] recentByBucket($bucket) error: $e');
    return const [];
  }
}

/// 앨범(bucket) 안의 모든 자산을 시스템 동의 하에 삭제하고 빈 디렉토리도
/// 정리. Android는 MediaStore.createDeleteRequest IntentSender를 사용해 시스템
/// 다이얼로그를 띄우고, 사용자가 동의하면 true, 취소하면 false를 반환한다.
///
/// iOS는 PhotoKit으로 구현 예정 — 현재는 항상 false (not implemented).
Future<bool> deleteAlbumNative(String bucket) async {
  if (!Platform.isAndroid) return false;
  const channel = MethodChannel('cubby/media_refresh');
  try {
    final res = await channel.invokeMethod<bool>(
      'deleteAlbum',
      {'bucket': bucket},
    );
    return res ?? false;
  } on PlatformException catch (e) {
    debugPrint('[mediaRefresh] deleteAlbum($bucket) error: $e');
    return false;
  } catch (e) {
    debugPrint('[mediaRefresh] deleteAlbum($bucket) error: $e');
    return false;
  }
}

/// Native MediaStore에서 가져온 한 자산. image와 video 양쪽을 표현.
class NativeRecent {
  NativeRecent({
    required this.id,
    required this.isVideo,
    required this.bytes,
    required this.dateTaken,
    required this.dateAdded,
    required this.data,
  });

  /// MediaStore _ID. image/video 컬렉션이 분리돼 있어 [isVideo]와 함께 키.
  final int id;
  final bool isVideo;

  /// JPEG-encoded thumbnail bytes (already sized).
  final Uint8List bytes;

  /// MediaStore.*.DATE_TAKEN (ms epoch). 0이면 unknown.
  final int dateTaken;

  /// MediaStore.*.DATE_ADDED (sec epoch).
  final int dateAdded;

  /// 절대 파일 경로. detail/share에서 원본 파일 직접 접근에 사용.
  final String? data;

  /// photo_manager의 createDateTime과 비교 가능한 ms epoch.
  /// dateTaken이 비어있을 때 dateAdded로 폴백.
  int get effectiveTakenMs {
    if (dateTaken > 0) return dateTaken;
    return dateAdded * 1000;
  }
}
