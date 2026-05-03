import 'package:go_router/go_router.dart';

import 'data/album.dart';
import 'ui/albums/albums_screen.dart';
import 'ui/camera/camera_screen.dart';
import 'ui/permission_gate_screen.dart';
import 'ui/photos/photos_screen.dart';

/// Route path builders. 한 곳에서 정의해 화면별로 path를 hand-build하지
/// 않게 한다. 이름이 바뀌면 여기만 고치면 됨.
class AppRoutes {
  const AppRoutes._();

  static const String onboarding = '/';
  static const String albums = '/albums';

  static String album(String name) =>
      '/albums/${Uri.encodeComponent(name)}';

  /// 새 앨범 생성 직후 PhotosScreen이 마운트되며 자동으로 카메라를 push하는
  /// "새 앨범 + 즉시 촬영" 흐름.
  static String albumWithImmediateShoot(String name) =>
      '${album(name)}?shoot=1';

  static String camera(String name) =>
      '/albums/${Uri.encodeComponent(name)}/camera';
}

/// Routes:
///   /                          PermissionGate (앱 진입; 권한 OK면 즉시 /albums)
///   /albums                    AlbumsScreen
///   /albums/:name              PhotosScreen
///       ?shoot=1               진입 직후 자동으로 카메라 push (새 앨범 + 즉시 촬영)
///   /albums/:name/camera       CameraScreen
///
/// `extra`로 [Album]을 그대로 넘겨 화면이 즉시 사용. extra가 없는
/// 경우(deep link/직접 URL 진입 등)에 대비해 화면 내부에서 catalog에서
/// 다시 resolve.
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (_, __) => const PermissionGateScreen(),
    ),
    GoRoute(
      path: '/albums',
      builder: (_, __) => const AlbumsScreen(),
      routes: [
        GoRoute(
          path: ':name',
          builder: (context, state) {
            final name = state.pathParameters['name']!;
            final extra = state.extra;
            final shoot = state.uri.queryParameters['shoot'] == '1';
            return PhotosScreen(
              albumName: name,
              album: extra is Album ? extra : null,
              shootImmediately: shoot,
            );
          },
          routes: [
            GoRoute(
              path: 'camera',
              builder: (context, state) {
                final name = state.pathParameters['name']!;
                final extra = state.extra;
                return CameraScreen(
                  albumName: name,
                  album: extra is Album ? extra : null,
                );
              },
            ),
          ],
        ),
      ],
    ),
  ],
);
