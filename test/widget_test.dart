import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:cubby/data/album_meta_store.dart';
import 'package:cubby/data/media_repository.dart';
import 'package:cubby/main.dart';

class _FakeMediaRepository implements MediaRepository {
  @override
  Future<PermissionState> requestPermission() async => PermissionState.denied;

  @override
  Future<void> presentLimitedPicker() async {}

  @override
  Future<void> openSystemSettings() async {}

  @override
  Future<List<AssetPathEntity>> getUserAlbums() async => const [];

  @override
  Future<AssetPathEntity?> findAlbumByName(String name) async => null;

  @override
  Future<AssetPathEntity?> createAlbum(String name) async => null;

  @override
  Future<List<AssetEntity>> getAssets(
    AssetPathEntity album, {
    int page = 0,
    int pageSize = 80,
  }) async => const [];

  @override
  Future<AssetEntity> saveImage({
    required Uint8List bytes,
    required String filename,
    required AssetPathEntity album,
  }) => throw UnimplementedError();

  @override
  Future<AssetEntity> saveVideo({
    required File file,
    required String filename,
    required AssetPathEntity album,
  }) => throw UnimplementedError();

  @override
  Future<List<String>> deleteAssets(List<AssetEntity> assets) async => const [];
}

class _FakeAlbumMetaStore implements AlbumMetaStore {
  @override
  Future<DateTime?> getCreatedAt(String albumId) async => null;

  @override
  Future<void> setCreatedAt(String albumId, DateTime createdAt) async {}

  @override
  Future<void> remove(String albumId) async {}
}

void main() {
  testWidgets('Albums screen shows loading then permission notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      CubbyApp(
        mediaRepository: _FakeMediaRepository(),
        albumMetaStore: _FakeAlbumMetaStore(),
      ),
    );

    expect(find.text('Albums'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.textContaining('권한이 필요합니다'), findsOneWidget);
  });
}
