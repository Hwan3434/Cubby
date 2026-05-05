# Flutter Personal Camera Album App - Design Document

> 1인 사용 목적의 Flutter 카메라/앨범 앱 설계 문서.
> 1차 목표: Android, 2차 목표: iOS. 배포 없음, 개인 사용.

-----

## 1. 프로젝트 개요

플러터 기반 카메라/앨범 앱. 사용자가 직접 앨범을 만들고 그 앨범 컨텍스트에서 카메라로 촬영해 사진/영상을 저장하는 구조. 시스템 사진앱과 폴더 단위로 연동되어 외부에서도 동일 앨범이 보여야 함.

**개발 정책**

- 표준 Flutter 패키지 위주 (커스텀 네이티브 플러그인 회피)
- 의존성 주입 + 공유 상태는 **Riverpod**. UI 로컬 상태(드래그/줌 등)는 `setState` 그대로
- Flutter 공식 문서 + Riverpod 공식 문서로 이해 가능한 단순 구조 유지 (별도 도메인-특화 abstraction 도입 자제)

-----

## 2. 요구사항

### 2.1 기능 요구사항 (확정)

|ID|기능                   |비고                   |
|--|---------------------|---------------------|
|F1|첫 화면에 앨범 목록 표시       |앨범명 + 사진 수            |
|F2|앨범 생성                |이름 입력                |
|F4|앨범별 사진 목록 화면         |촬영일 내림차순 고정          |
|F5|앨범별 카메라 화면           |해당 앨범 ID를 받아 그 앨범에 저장|
|F6|사진/영상 삭제             |OS 권한 다이얼로그 자동 처리    |
|F7|사진의 촬영일 표시           |EXIF/시스템 메타          |
|F8|시스템 사진앱/갤러리에 동일 앨범 노출|폴더 단위 자동 연동          |

### 2.2 명시적 비요구사항 (제외)

- 앨범 이름 변경 (photo_manager 미지원, native channel 도입 정당화 부족 → MVP 제외)
- 드래그앤드롭 사진 순서 변경 (정렬은 촬영일로 고정)
- 사용자 정의 정렬과 시스템 갤러리 정렬의 동기화
- 클라우드 백업/공유
- 사진 편집 기능

-----

## 3. 기술적 의사결정 기록

### Decision 1: 시스템 갤러리/사진앱 연동 방식

**결정**: `photo_manager` 패키지로 추상화하여 Android의 MediaStore와 iOS의 PHAssetCollection을 단일 인터페이스로 다룸.

**근거**:

- Android와 iOS의 미디어 모델이 근본적으로 다름 (Android = 파일 시스템 폴더, iOS = PHAssetCollection 참조 모음)
- photo_manager가 양 플랫폼을 `AssetPathEntity`(앨범) / `AssetEntity`(사진/영상)로 추상화
- 자체 네이티브 플러그인 작성 회피

### Decision 2: 사진 정렬

**결정**: 촬영일(`AssetEntity.createDateTime`) 내림차순 고정. 자체 `sortIndex` 컬럼 미관리.

**근거**:

- Android MediaStore에 사용자 정의 정렬 컬럼이 없음 → 시스템 갤러리에 사용자 정렬을 반영할 표준 API 부재
- 앱 내 정렬과 시스템 정렬을 일치시키는 것이 사양상 더 중요

### Decision 3: 앨범 생성일 미관리

**결정**: 앱 차원의 생성일 메타데이터 자체를 두지 않음.

**근거**:

- iOS `PHAssetCollection.startDate`는 "내부 자산 중 가장 오래된 것"이지 진짜 생성일이 아님; 빈 앨범은 nil
- Android는 폴더 자체의 생성 시각을 안정적으로 얻을 수 없음
- SharedPreferences로 자체 보관할 수도 있으나 앱 재설치 시 사라져 사용자에 일관성을 주지 못함
- 결국 사진 자체의 EXIF 촬영일(F7)이 실질 정보 → 앨범 생성일은 **표시하지 않음**

### Decision 4: 카메라 촬영 → 저장 파이프라인

**결정**: `camera` 패키지로 임시 위치에 촬영 → photo_manager의 editor API로 특정 앨범에 등록.

**근거**:

- Android scoped storage 정책상 임의 경로 직접 쓰기 불가 → MediaStore 경유 필요
- iOS는 디스크에 단순 쓰기로는 사진 앱에 노출 안 됨 → PhotoKit 등록 필요
- `image_picker`는 시스템 카메라 앱에 종속되어 앨범 컨텍스트 유지가 어려움

### Decision 5: Android 저장 root 통일 (Pictures/&lt;name&gt;/)

**결정**: 사진과 영상 모두 `Pictures/<albumName>/`로 저장. 영상을 `Movies/<albumName>/`로 분리하지 않음.

**근거**:

- photo_manager의 Android 구현은 BUCKET_DISPLAY_NAME이 같아도 root path가 다르면 별개 `AssetPathEntity`로 분리 인식. 사진은 `Pictures/<name>/`에, 영상은 `Movies/<name>/`에 두면 한 앨범인데 cubby UI에 카드가 두 개로 보이는 문제 발생.
- 한 폴더 = 한 앨범이 사용자/외부 도구(파일 매니저, 다른 갤러리 앱) mental model에 일치. PC에서 USB로 봐도 한 폴더라 일관됨.
- Samsung 갤러리 등 일부 OEM 갤러리는 BUCKET 기준이라 root가 Pictures여도 영상은 영상 카테고리로 자연스럽게 분류됨. `Environment.DIRECTORY_PICTURES`/`MOVIES` 분리는 권장 위치일 뿐 강제는 아님.
- `MediaRepository.saveImage`/`saveVideo`가 같은 `mediaRoot: 'Pictures'`를 쓰면 `findBucketDirs`/`gridItems` 등 보조 코드의 "두 root 합치기" 분기가 단순화됨.

**호환성**:

- 기존 분리 저장(Decision 5 도입 이전)으로 만들어진 `Movies/<name>/` 잔재 폴더는 native `findBucketDirs`/`scanCameraDirs`가 계속 모든 root를 walk하므로 자연스럽게 정리됨. 새 자산은 Pictures에만 들어가니 시간이 지나면 Movies 잔재는 사라짐.

-----

## 4. 패키지 스택

|역할         |패키지                  |버전 가이드|
|-----------|---------------------|------|
|시스템 미디어 추상화|`photo_manager`      |`^3.x`|
|카메라 촬영     |`camera` (Flutter 공식)|최신    |
|권한 처리 보조   |`permission_handler` |최신    |

**의도적으로 배제**:

- `image_picker` — 시스템 카메라 앱 호출 방식이라 앨범 컨텍스트 유지 어려움
- `gallery_saver` / `image_gallery_saver` — 유지보수 둔화, 앨범 지정 기능 약함
- `media_store_plus` — Android 전용

-----

## 5. 폴더 구조

```
lib/
├─ data/
│  └─ media_repository.dart       # photo_manager 래퍼
├─ ui/
│  ├─ albums/
│  │  ├─ albums_screen.dart       # 앨범 목록 (생성/진입)
│  │  └─ album_tile.dart
│  ├─ photos/
│  │  ├─ photos_screen.dart       # 사진 그리드 (촬영일 정렬, 삭제)
│  │  └─ photo_thumbnail.dart
│  └─ camera/
│     └─ camera_screen.dart       # 앨범 ID 받아서 촬영 → 저장
├─ app.dart                       # InheritedWidget으로 Repository 주입
└─ main.dart
```

-----

## 6. 핵심 인터페이스 시그니처

### 6.1 MediaRepository

> 아래 시그니처는 초기 설계 스케치. 실제 구현은 `AlbumDisplay` (sealed: `RealAlbum` / `PlaceholderAlbum`)를 도입해 Android 빈 앨범 함정을 해소함. 최신 계약은 [`lib/data/media_repository.dart`](../lib/data/media_repository.dart) 참고.

```dart
abstract class MediaRepository {
  /// 시스템 권한 확인/요청. iOS limited 상태 포함 처리.
  Future<PermissionState> requestPermission();

  /// 앱이 만든 사용자 앨범 목록만 반환 (시스템 스마트 앨범 제외).
  Future<List<AssetPathEntity>> getUserAlbums();

  /// 새 앨범 생성. 이미 존재하는 이름이면 그 앨범 반환.
  Future<AssetPathEntity> createAlbum(String name);

  /// 앨범 내 사진/영상 목록. 촬영일 내림차순.
  Future<List<AssetEntity>> getAssets(
    AssetPathEntity album, {
    int page = 0,
    int pageSize = 80,
  });

  /// 카메라 촬영물을 특정 앨범에 저장.
  /// Android: MediaStore에 INSERT (DCIM/[albumName]/ 또는 Pictures/[albumName]/)
  /// iOS: PHAssetCreationRequest + 앨범에 addAssets
  Future<AssetEntity> saveImage({
    required Uint8List bytes,
    required String filename,
    required AssetPathEntity album,
  });

  Future<AssetEntity> saveVideo({
    required File file,
    required String filename,
    required AssetPathEntity album,
  });

  /// 사진/영상 삭제.
  /// Android 11+: 시스템 동의 다이얼로그 자동 표시
  /// iOS: 휴지통 이동 다이얼로그 자동 표시
  Future<List<String>> deleteAssets(List<AssetEntity> assets);
}
```

-----

## 7. 권한 설정

### 7.1 Android (`android/app/src/main/AndroidManifest.xml`)

```xml
<!-- 미디어 읽기 (Android 13+) -->
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />

<!-- 부분 권한 (Android 14+): 사용자가 일부 사진만 허용한 상태에서
     시스템 사진 선택기로 추가 허용 다이얼로그를 띄우는 데 필요 -->
<uses-permission android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED" />

<!-- 미디어 읽기 (Android 12 이하) -->
<uses-permission
    android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />

<!-- 카메라/마이크 -->
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />

<!-- (선택) 촬영 위치 EXIF 보존 -->
<uses-permission android:name="android.permission.ACCESS_MEDIA_LOCATION" />

<application ...>
    <!-- ... -->
</application>
```

**Gradle 설정**:

- `compileSdk` 34+
- `minSdk` 21+ 권장
- `targetSdk` 34 권장

### 7.2 iOS (`ios/Runner/Info.plist`)

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>앨범과 사진을 보기 위해 사진 접근 권한이 필요합니다.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>촬영한 사진을 앨범에 저장하기 위해 권한이 필요합니다.</string>

<key>NSCameraUsageDescription</key>
<string>사진과 영상 촬영을 위해 카메라 권한이 필요합니다.</string>

<key>NSMicrophoneUsageDescription</key>
<string>영상 촬영을 위해 마이크 권한이 필요합니다.</string>
```

**최소 iOS 버전**: 13.0 (camera 플러그인이 iOS 13+ 요구)

**의존성 매니저**: Swift Package Manager(SPM) 우선 사용. CocoaPods는 fallback.

- Flutter 3.24+에서 SPM 지원, 3.41 기준 opt-in.
- 활성화: `flutter config --enable-swift-package-manager` (개발 머신마다 1회)
- 플러그인이 `Package.swift`를 제공하면 SPM, 아니면 CocoaPods로 자동 폴백
- CocoaPods는 2026-12-02부로 read-only. 신규 의존성은 SPM 호환 버전으로 픽스
- `camera` 0.12.x → `camera_avfoundation` 0.10.x 가 SPM 지원함

-----

## 8. OS별 주요 차이

### 8.1 Android

- **저장 경로**: 사진/영상 모두 `Pictures/[앨범명]/`에 저장 (Decision 5). DCIM은 시스템 카메라 영역이라 피하고, Movies로 영상을 분리하면 photo_manager가 같은 앨범을 둘로 인식하는 함정이 있어 통일.
- **권한 모델**: 앱이 만든 파일은 권한 없이 자유롭게 읽기/쓰기 가능. 다른 앱이 만든 파일 수정/삭제는 `MediaStore.createWriteRequest()` / `createDeleteRequest()` 다이얼로그 필요
- **앱 재설치 시**: 이전에 만든 파일에 대한 쓰기 권한을 자동으로 잃음 → 사용자 동의 다이얼로그 필요
- **앨범 이름 변경**: 폴더 rename으로 구현됨. 일부 갤러리 앱은 캐시 갱신까지 잠깐 빈 앨범처럼 보일 수 있음

### 8.2 iOS

- **모델 차이**: 파일 시스템 직접 노출 X. 모든 사진은 "라이브러리"에 원본이 있고, 앨범은 그 사진들의 참조 모음일 뿐. 같은 사진이 여러 앨범에 들어갈 수 있음
- **Limited Photos** (iOS 14+): 사용자가 "선택한 사진만 허용" 모드를 고를 수 있음. `PermissionState.limited` 분기 처리 필수
- **HEIC 형식**: iOS 기본 촬영 포맷이 HEIC. Flutter `Image` 위젯이 HEIC 직접 렌더링 불가 → photo_manager의 thumbnail API 사용 또는 JPEG 변환
- **iCloud 사진**: 원본이 iCloud에만 있는 경우 다운로드 콜백(`progressHandler`) 처리 필요
- **앨범 이름 사용자 변경 가능성**: 사용자가 사진 앱에서 앨범 이름을 직접 바꾸면 앱과 어긋남. 표시 전 시스템 값 재조회 필요

-----

## 9. 카메라 → 저장 파이프라인 (의사 코드)

```dart
Future<AssetEntity> capturePhoto({
  required CameraController controller,
  required AssetPathEntity targetAlbum,
}) async {
  // 1. 임시 위치에 촬영
  final XFile xfile = await controller.takePicture();
  final Uint8List bytes = await xfile.readAsBytes();

  // 2. photo_manager로 시스템 미디어 저장소에 등록
  //    (Android: MediaStore INSERT, iOS: PHAssetCreationRequest)
  final AssetEntity asset = await PhotoManager.editor.saveImage(
    bytes,
    filename: 'IMG_${DateTime.now().millisecondsSinceEpoch}.jpg',
    relativePath: 'DCIM/${targetAlbum.name}', // Android에서만 의미 있음
  );

  // 3. iOS의 경우 앨범에 명시적으로 추가
  if (Platform.isIOS) {
    await PhotoManager.editor.darwin.copyAssetToAlbum(
      asset: asset,
      pathEntity: targetAlbum,
    );
  }

  // 4. 임시 파일 정리
  await File(xfile.path).delete().catchError((_) {});

  return asset;
}
```

> 위 코드는 패키지 API 시그니처 기준 의사 코드. 실제 photo_manager 최신 버전 API 확인 필요.

-----

## 10. 알려진 함정 (Known Pitfalls)

|함정                      |영향                   |대응                             |
|------------------------|---------------------|-------------------------------|
|HEIC 렌더링 불가             |iOS에서 사진 표시 깨짐       |thumbnail API 사용, 필요 시 JPEG 변환 |
|Limited Photos 모드       |iOS에서 일부만 보임         |`PermissionState.limited` UI 안내|
|iCloud 미다운로드 자산         |iOS에서 원본 접근 실패       |progressHandler로 다운로드 처리       |
|앱 재설치 후 권한 손실           |Android에서 기존 파일 수정 불가|createWriteRequest 다이얼로그       |
|PHAssetCollection 사용자 변경|iOS에서 앱과 이름 어긋남      |표시 전 시스템 값 재조회                 |
|Android 빈 앨범 생성 불가       |MediaStore에 폴더만 만드는 API 없음 |메모리 전용 `PlaceholderAlbum` 도입. 사용자에겐 즉시 앨범으로 보이고, 첫 자산 저장 시 시스템 폴더가 materialise되며 자동 promote. 영속성 없음 (앱 재시작 시 자리표시자는 사라짐).|
|Android 외부 카메라 촬영 stale | 백그라운드 동안 외부 카메라가 commit한 새 사진을 photo_manager가 같은 프로세스 lifetime 안에서 못 봄 (MediaProvider binder cache stale, `MediaScannerConnection.scanFile`도 미해소) | (1) `MainActivity.onCreate`에서 `MediaStore.{Images,Video}` URI에 ContentObserver 등록 — 외부 변화 시점에 우리 프로세스 binder cache가 자동 invalidate. (2) Native `recentByBucket`로 MediaStore 직접 쿼리해 최신 N장을 받아 `SyntheticImageAsset`(file path 포함)으로 감싼 뒤 `AlbumLive.gridItems`가 photo_manager items 위에 끼워줌. (3) Detail/share는 synthetic의 originFile/originBytes가 진짜 파일을 디코딩해 정상 동작. selection delete만은 photo_manager가 fresh를 따라잡을 때까지 대기. |
| Android 같은 BUCKET 다른 root → 두 앨범 카드 | 한 앨범의 사진을 `Pictures/<name>/`, 영상을 `Movies/<name>/`로 분산 저장하면 photo_manager가 별개 `AssetPathEntity`로 분리 인식 → 사용자에겐 같은 이름 카드 두 개 | Decision 5: 사진/영상 모두 `Pictures/<albumName>/`로 통일 저장. 기존 분리 잔재는 native delete 흐름이 모든 root를 walk해 같이 정리. |

-----

## 11. 개발 단계 (PoC 로드맵)

### Phase 1: 기반 (반나절)

- 프로젝트 생성, 패키지 추가, 권한 설정
- `MediaRepository` 인터페이스 정의 + photo_manager 구현체
- 권한 요청 + 앨범 목록 화면 (시스템 기존 앨범 표시)

### Phase 2: 앨범 CRUD (반나절)

- 앨범 생성 (이름변경/생성일은 비요구사항)
- 앨범 목록 UI 완성

### Phase 3: 카메라 → 저장 (1일) — 가장 까다로움

- 카메라 화면 (`camera` 패키지)
- 촬영 → 임시 저장 → photo_manager로 앨범에 등록
- Android/iOS 모두에서 시스템 갤러리에 노출 확인

### Phase 4: 사진 목록 + 삭제 (반나절)

- 사진 그리드 (촬영일 정렬, 페이지네이션)
- 촬영일 표시
- 삭제 (시스템 다이얼로그 흐름)

### Phase 5: 영상 + 마무리 (반나절)

- 영상 촬영
- iOS Limited Photos 처리
- 에러 처리, 로깅

**예상 총 작업량**: 1인 기준 4~5일

-----

## 12. 향후 확장 시 고려사항

배포로 전환 시 추가 검토 필요한 항목들 (현 PoC 범위 외):

- 앨범 커버 이미지 캐싱 전략
- 백업/내보내기
- 다국어 (특히 iOS 시스템 앨범명 로컬라이즈)

-----

## 13. 참고 자료

- [photo_manager - pub.dev](https://pub.dev/packages/photo_manager)
- [Android Scoped Storage 공식 문서](https://developer.android.com/training/data-storage/shared/media)
- [Apple PhotoKit 공식 문서](https://developer.apple.com/documentation/photos)
- [camera plugin - pub.dev](https://pub.dev/packages/camera)
