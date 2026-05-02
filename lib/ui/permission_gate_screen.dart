import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'albums/albums_screen.dart';

/// Hard permission gate at app start. Photos must be granted (or limited
/// on iOS) for the app to function; on outright denial we exit so the user
/// is taken back out, per the design call.
class PermissionGateScreen extends StatefulWidget {
  const PermissionGateScreen({super.key});

  @override
  State<PermissionGateScreen> createState() => _PermissionGateScreenState();
}

class _PermissionGateScreenState extends State<PermissionGateScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  Future<void> _request() async {
    // Android 13+ split media into READ_MEDIA_IMAGES and
    // READ_MEDIA_VIDEO. Permission.photos alone only covers images, so
    // a user who hits "Allow" without ticking the (vendor-specific)
    // video toggle ends up unable to see videos in the grid. Request
    // both at once. iOS has a single Photos permission and maps both
    // entries to the same prompt, so this is safe there too.
    final results = await [
      Permission.photos,
      Permission.videos,
    ].request();
    if (!mounted) return;
    final allOk = results.values.every(
      (s) => s.isGranted || s.isLimited,
    );
    if (allOk) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AlbumsScreen()),
      );
      return;
    }
    await _showDeniedAndExit();
  }

  Future<void> _showDeniedAndExit() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('권한 필요'),
        content: const Text('사진 라이브러리 접근 권한이 없으면 앱을 사용할 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('종료'),
          ),
        ],
      ),
    );
    // SystemNavigator.pop closes the activity on Android; iOS no-ops.
    // exit(0) terminates the process on both. App Store would not allow
    // this, but the design is personal-use only (no distribution).
    await SystemNavigator.pop();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
