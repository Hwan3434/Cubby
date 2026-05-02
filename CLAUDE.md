# CLAUDE.md — Cubby

개인용 Flutter 카메라/앨범 앱. 1인 사용 목적, 배포 없음, Android 1차 / iOS 2차.

설계 근거와 결정 이력은 [docs/design.md](docs/design.md), 회귀 검증 항목은 [docs/smoke-test.md](docs/smoke-test.md) 참고.

## 빌드 / 실행

```bash
flutter config --enable-swift-package-manager   # iOS 작업 시, 머신마다 1회
flutter pub get
flutter run
```

빠른 검사:

```bash
flutter analyze   # issue 0 유지
flutter test
```

## 툴체인 / 타깃

- Flutter SDK: 3.41+
- Android: minSdk 21, target/compileSdk 34
- iOS: deployment target 13.0, 의존성은 SPM 우선 (CocoaPods는 fallback)

## 아키텍처 한눈에

- **DI / 공유 상태**: **Riverpod**. `main.dart`에서 `ProviderScope`로 감싸고, 화면은 `ConsumerStatefulWidget` / `ConsumerWidget`. `MediaRepository`는 `mediaRepositoryProvider`로 주입, 사진 캐시는 `photoCacheProvider(albumId)` (family, riverpod_generator로 생성).
- **UI 로컬 state는 setState 그대로**. 드래그 오프셋, 줌 상태, 페이지 인덱스 등 한 화면 안에서만 의미있는 상태는 provider에 안 올림.
- **데이터 계층**: `MediaRepository`는 `photo_manager`를 추상화. `PhotoManagerMediaRepository`가 유일한 구현체. 테스트는 `mediaRepositoryProvider.overrideWithValue(fake)`로 swap.
- **UI 진입점**: `main.dart` → `CubbyApp` → `PermissionGateScreen` → `AlbumsScreen` → `PhotosScreen` → `openPhotoDetail` / `openVideoDetail` / `CameraScreen`.
- **사진 정렬**: 촬영일 내림차순 고정. 자체 정렬 인덱스 없음.

```
lib/
├─ data/
│  ├─ media_repository.dart         # photo_manager 래퍼 + mediaRepositoryProvider
│  ├─ photo_cache.dart              # photoCacheProvider family (albumId 키)
│  └─ photo_cache.g.dart            # 자동 생성 (build_runner)
├─ ui/
│  ├─ permission_gate_screen.dart   # 권한 게이트 (앱 진입)
│  ├─ albums/albums_screen.dart
│  ├─ photos/photos_screen.dart
│  ├─ photos/photo_detail_route.dart  # 사진 풀스크린 (Hero+pinch+drag)
│  ├─ photos/video_detail_route.dart  # 영상 풀스크린
│  ├─ camera/camera_screen.dart
│  └─ snackbar.dart
├─ app.dart
└─ main.dart
```

### Riverpod 코드 생성

`@riverpod` annotation을 쓰는 파일을 추가/수정하면 `.g.dart`를 다시 생성해야 합니다:

```bash
dart run build_runner build
```

`.g.dart` 파일은 git에 commit합니다 (CI 없음, 항상 build_runner 보장 안 됨).

## 작업 시 반드시 지킬 정책

### 스코프 (design.md §2.2)

다음은 **명시적 비요구사항**. 구현 요청을 받아도 먼저 사용자에게 확인:
- 앨범 이름 변경 (photo_manager 미지원, native channel 도입 정당화 부족)
- 드래그앤드롭 정렬 / 사용자 정의 정렬
- 클라우드 백업/공유, 사진 편집

### 패키지 정책

- **표준 Flutter 패키지 위주.** 커스텀 네이티브 플러그인 회피.
- 새 패키지 추가 전 design.md §4의 "의도적으로 배제" 목록 확인. `image_picker`, `gallery_saver`/`image_gallery_saver`, `media_store_plus`는 의도적으로 안 씁니다.
- 현재 사용 중: `photo_manager`, `camera`, `permission_handler`, `share_plus`, `photo_view`, `video_player`.

### MediaRepository 계약

- **앨범 타입은 `AlbumDisplay` (sealed)**. 두 변종: `RealAlbum`(시스템에 실재) / `PlaceholderAlbum`(메모리 전용 자리표시자). UI는 항상 `AlbumDisplay`로 다루며 photo_manager의 `AssetPathEntity`를 직접 노출하지 않음.
- `createAlbum(name)`은 **항상 `AlbumDisplay`를 반환**. 같은 이름 앨범(real/placeholder 무관) 존재 시 `DuplicateAlbumException` throw — null 반환 없음.
  - iOS/macOS: 즉시 시스템에 실제 빈 앨범 생성 → `RealAlbum`
  - Android: 메모리 자리표시자만 생성 → `PlaceholderAlbum`. 첫 자산 저장 시 시스템 폴더가 materialise되며 자동으로 `RealAlbum`으로 promote됨.
- **자리표시자는 메모리에만 존재** — 앱 재시작/크래시 시 사라짐. 의도된 동작 (사진 한 장도 안 들어간 앨범은 영속될 가치 없음).
- `saveImage`/`saveVideo`는 Android에서 `Pictures/<albumName>/` 또는 `Movies/<albumName>/`에 저장. iOS는 라이브러리에 추가 후 `copyAssetToPath`로 앨범에 링크 (PhotoKit soft-link, RealAlbum에 한함).
- Android에서 같은 표시명 앨범을 중복 bucket으로 쪼개지 않도록 `RealAlbum`은 `album.source.relativePathAsync`를 우선 사용. 자리표시자는 그게 없으니 `<mediaRoot>/<name>` 컨벤션으로 첫 폴더 생성.
- `getAssets(PlaceholderAlbum)`는 빈 리스트 반환 (platform-channel 호출 자체 안 함).
- `deleteAssets`는 Android 11+ / iOS에서 **시스템 동의 다이얼로그가 자동으로 뜸**. 앱 자체 확인 다이얼로그를 추가하지 말 것 (이중 확인됨).

### 플랫폼 함정 (design.md §10)

| 함정 | 대응 |
|---|---|
| iOS HEIC 직접 렌더 불가 | 썸네일 API 사용. 원본 표시 시 별도 처리. `Image.memory(asset.originBytes)` 식의 직접 디코딩 금지 |
| iOS Limited Photos | `PermissionState.limited` 분기 필수. 게이트 통과 후에도 외부에서 권한 회수 가능 → `AlbumsScreen`에서 재확인 |
| iCloud 미다운로드 자산 | 원본 접근 시 시간 소요 가능. progressHandler 미구현 상태 — 대용량 자산 첫 접근 시 잠깐 멈출 수 있음 |
| Android 앱 재설치 후 권한 손실 | 기존 파일 삭제/수정 시 시스템 다이얼로그 (자동 처리됨) |
| Android 빈 앨범 생성 불가 (OS 제약) | `PlaceholderAlbum`으로 UX상 해소. MediaRepository 계약 참고 |
| 화면에 사진 가려짐 (Android 15+ edge-to-edge) | 모든 `Scaffold` body는 `SafeArea(top: false)`로 감쌀 것. AppBar 있는 화면은 top inset이 자동 처리되니 bottom만 보호 |

### 변경 시 회귀 회피

- UI 변경 시 [docs/smoke-test.md](docs/smoke-test.md)의 해당 섹션 항목을 직접 확인.
- `flutter analyze`는 issue 0 유지가 기준.
- design.md의 결정(Decision 1~4)을 뒤집는 변경은 design.md 수정과 함께.

## 모르겠으면

- 기능 범위 의문 → design.md §2 (요구/비요구사항)
- 패키지/접근 방식 의문 → design.md §3 (Decision 1~4) + §4 (패키지 스택)
- 동작 검증 방법 → smoke-test.md
