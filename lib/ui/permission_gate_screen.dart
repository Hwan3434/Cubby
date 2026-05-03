import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'albums/albums_screen.dart';
import 'theme/cubby_theme.dart';
import 'theme/cubby_tokens.dart';
import 'widgets/cubby_mark.dart';

/// Hard permission gate at app start. Photos must be granted (or limited
/// on iOS) for the app to function; on outright denial we exit so the user
/// is taken back out, per the design call.
class PermissionGateScreen extends StatefulWidget {
  const PermissionGateScreen({super.key});

  @override
  State<PermissionGateScreen> createState() => _PermissionGateScreenState();
}

class _PermissionGateScreenState extends State<PermissionGateScreen> {
  bool _requesting = false;
  // 첫 빌드 동안 권한 상태를 묻는 동안엔 온보딩 UI를 노출하지 않는다.
  // 이미 허용된 사용자에게 한 프레임이라도 온보딩이 깜빡이는 걸 막는다.
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSkipOnboarding());
  }

  Future<void> _maybeSkipOnboarding() async {
    final photos = await Permission.photos.status;
    final videos = await Permission.videos.status;
    if (!mounted) return;
    final ok = (photos.isGranted || photos.isLimited) &&
        (videos.isGranted || videos.isLimited);
    if (ok) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AlbumsScreen()),
      );
      return;
    }
    setState(() => _checking = false);
  }

  Future<void> _continueAndRequest() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      // Android 13+ split media into READ_MEDIA_IMAGES and
      // READ_MEDIA_VIDEO. Permission.photos alone only covers images, so
      // a user who hits "Allow" without ticking the (vendor-specific)
      // video toggle ends up unable to see videos in the grid. Request
      // both at once. iOS has a single Photos permission and maps both
      // entries to the same prompt, so this is safe there too.
      final results = await [
        Permission.photos,
        Permission.videos,
        Permission.camera,
        Permission.microphone,
      ].request();
      if (!mounted) return;
      final photosOk = [Permission.photos, Permission.videos].every(
        (p) => results[p]?.isGranted == true || results[p]?.isLimited == true,
      );
      if (photosOk) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AlbumsScreen()),
        );
        return;
      }
      await _showDeniedAndExit();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
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
    await SystemNavigator.pop();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    if (_checking) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: CubbySpacing.xl),
              Row(
                children: [
                  const CubbyMark(size: 26),
                  const SizedBox(width: 10),
                  Text(
                    'Cubby',
                    style: CubbyType.titleLg.copyWith(
                      letterSpacing: -0.3,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 56),
              Text(
                '찍은 것을\n다시 들여다볼\n작은 칸.',
                style: CubbyType.displayMd.copyWith(
                  height: 1.08,
                  letterSpacing: -0.6,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '앨범 안에서 바로 찍고, 앨범 안에서\n다시 봅니다. 클라우드 없음, 공유 안 함.',
                style: CubbyType.bodySm.copyWith(
                  fontSize: 15,
                  color: cubby.body,
                ),
              ),
              const SizedBox(height: CubbySpacing.xl + 4),
              const _PermRow(
                icon: Icons.photo_library_outlined,
                label: '사진 라이브러리',
                detail: '앨범과 사진을 시스템 사진 앱과 같은 곳에 둡니다.',
              ),
              const _PermRow(
                icon: Icons.photo_camera_outlined,
                label: '카메라',
                detail: '앨범 안에서 사진과 영상을 찍습니다.',
              ),
              const _PermRow(
                icon: Icons.mic_none_outlined,
                label: '마이크',
                detail: '영상에 소리를 함께 담습니다.',
                isLast: true,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _requesting ? null : _continueAndRequest,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: const RoundedRectangleBorder(
                      borderRadius: CubbyRadius.lgAll,
                    ),
                    textStyle: CubbyType.buttonLabel.copyWith(fontSize: 16),
                  ),
                  child: _requesting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Text('계속'),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  '권한은 다음 화면에서 시스템이 하나씩 묻습니다.',
                  style: CubbyType.caption.copyWith(
                    fontSize: 12,
                    color: cubby.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermRow extends StatelessWidget {
  const _PermRow({
    required this.icon,
    required this.label,
    required this.detail,
    this.isLast = false,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: cubby.hairline, width: 1),
              ),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: cubby.surfaceCard,
              borderRadius: CubbyRadius.lgAll,
            ),
            child: Icon(icon, size: 20, color: scheme.onSurface),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: CubbyType.titleSm.copyWith(
                      fontSize: 15,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: CubbyType.caption.copyWith(
                      height: 1.5,
                      color: cubby.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
