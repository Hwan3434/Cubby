import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native MediaScannerConnection.scanFile 호출.
///
/// Android에서 외부 카메라가 cubby 백그라운드 동안 사진을 추가했는데
/// photo_manager가 같은 프로세스 안에서 새 자산을 못 보는 문제 (Android
/// MediaProvider의 binder cache가 우리 프로세스에 stale로 잡혀 있음)를
/// 우회하기 위함. scanFile이 MediaProvider에 pending inserts를 commit
/// 시키면 다음 ContentResolver.query가 fresh 결과를 받는다.
///
/// iOS는 이 문제 자체가 없어 no-op.
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

/// Native MediaStore에서 [bucket] (앨범 이름)에 속한 가장 최근 image의
/// cover 정보를 직접 가져온다. photo_manager가 같은 프로세스 lifetime
/// 안에서 가장 최근 1장을 누락하는 한계를 우회하기 위함.
///
/// iOS는 MediaStore이 없어 항상 null. Android에서만 의미.
Future<NativeCover?> fetchLatestCoverNative(
  String bucket, {
  int size = 200,
}) async {
  if (!Platform.isAndroid) return null;
  const channel = MethodChannel('cubby/media_refresh');
  try {
    final dynamic res = await channel.invokeMethod<dynamic>(
      'latestCoverByBucket',
      {'bucket': bucket, 'size': size},
    );
    if (res is! Map) return null;
    final bytes = res['bytes'];
    if (bytes is! Uint8List) return null;
    final id = (res['id'] as num?)?.toInt() ?? 0;
    final dateTaken = (res['dateTaken'] as num?)?.toInt() ?? 0;
    final dateAdded = (res['dateAdded'] as num?)?.toInt() ?? 0;
    final data = res['data'] as String?;
    return NativeCover(
      id: id,
      bytes: bytes,
      dateTaken: dateTaken,
      dateAdded: dateAdded,
      data: data,
    );
  } on PlatformException catch (e) {
    debugPrint('[mediaRefresh] latestCoverByBucket($bucket) error: $e');
    return null;
  } catch (e) {
    debugPrint('[mediaRefresh] latestCoverByBucket($bucket) error: $e');
    return null;
  }
}

class NativeCover {
  NativeCover({
    required this.id,
    required this.bytes,
    required this.dateTaken,
    required this.dateAdded,
    required this.data,
  });

  /// MediaStore _ID
  final int id;

  /// JPEG-encoded thumbnail bytes (already sized).
  final Uint8List bytes;

  /// MediaStore.Images.Media.DATE_TAKEN (ms epoch). 0이면 unknown.
  final int dateTaken;

  /// MediaStore.Images.Media.DATE_ADDED (sec epoch).
  final int dateAdded;

  /// 절대 파일 경로. 디버깅용.
  final String? data;

  /// photo_manager의 createDateTime과 비교 가능한 ms epoch.
  /// dateTaken이 비어있을 때 dateAdded로 폴백.
  int get effectiveTakenMs {
    if (dateTaken > 0) return dateTaken;
    return dateAdded * 1000;
  }
}
