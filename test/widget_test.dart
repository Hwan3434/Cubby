import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:cubby/data/media_repository.dart';
import 'package:cubby/main.dart';

class _FakeMediaRepository implements MediaRepository {
  @override
  Future<PermissionState> requestPermission() async => PermissionState.denied;

  @override
  Future<List<AssetPathEntity>> getUserAlbums() async => const [];
}

void main() {
  testWidgets('Albums screen shows loading then permission notice', (
    tester,
  ) async {
    await tester.pumpWidget(CubbyApp(mediaRepository: _FakeMediaRepository()));

    expect(find.text('Albums'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.textContaining('권한이 필요합니다'), findsOneWidget);
  });
}
