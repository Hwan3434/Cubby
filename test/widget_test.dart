import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart' show PermissionState;

import 'package:cubby/data/album.dart';
import 'package:cubby/data/media_asset.dart';
import 'package:cubby/data/media_repository.dart';
import 'package:cubby/ui/albums/albums_screen.dart';
import 'package:cubby/ui/theme/cubby_theme.dart';

class _FakeMediaRepository implements MediaRepository {
  @override
  Future<PermissionState> requestPermission() async => PermissionState.denied;

  @override
  Future<void> presentLimitedPicker() async {}

  @override
  Future<List<Album>> getUserAlbums() async => const [];

  @override
  Future<Album> createAlbum(String name) => throw UnimplementedError();

  @override
  Future<List<MediaAsset>> getAssets(
    Album album, {
    int page = 0,
    int pageSize = 80,
  }) async => const [];

  @override
  Future<MediaAsset> saveImage({
    required Uint8List bytes,
    required String filename,
    required Album album,
  }) => throw UnimplementedError();

  @override
  Future<MediaAsset> saveVideo({
    required File file,
    required String filename,
    required Album album,
  }) => throw UnimplementedError();

  @override
  Future<List<String>> deleteAssets(List<MediaAsset> assets) async => const [];

  @override
  Future<bool> deleteAlbum(Album album) async => false;
}

void main() {
  testWidgets('Albums screen shows loading then permission notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaRepositoryProvider.overrideWithValue(_FakeMediaRepository()),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const AlbumsScreen(),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.textContaining('권한이 필요합니다'), findsOneWidget);
  });
}
