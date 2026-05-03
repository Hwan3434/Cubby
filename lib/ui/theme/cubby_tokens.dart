import 'package:flutter/material.dart';

/// Light/Dark에 무관한 spacing 토큰. colors_and_type.css 기준.
class CubbySpacing {
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
  static const section = 96.0;
}

class CubbyRadius {
  static const xs = Radius.circular(4);
  static const sm = Radius.circular(6);
  static const md = Radius.circular(8);
  static const lg = Radius.circular(12);
  static const xl = Radius.circular(16);
  static const xxl = Radius.circular(28);
  static const pill = Radius.circular(9999);

  static const mdAll = BorderRadius.all(md);
  static const lgAll = BorderRadius.all(lg);
  static const xlAll = BorderRadius.all(xl);
  static const xxlAll = BorderRadius.all(xxl);
}

/// Cubby 디자인 시스템의 typography 토큰.
///
/// 디자인 시스템은 display에 serif (Fraunces 류)를 가정하지만, cubby는
/// 라이선스/번들 사이즈 단순화를 위해 display/body 모두 Pretendard 단일로
/// 운영한다. 디자인 의도된 시각 차별은 size/weight/letterSpacing으로만 표현.
class CubbyType {
  static const _displayFamily = 'Pretendard';
  static const _bodyFamily = 'Pretendard';

  static const displayXl = TextStyle(
    fontFamily: _displayFamily,
    fontSize: 64,
    height: 1.05,
    letterSpacing: -1.5,
    fontWeight: FontWeight.w400,
  );
  static const displayLg = TextStyle(
    fontFamily: _displayFamily,
    fontSize: 48,
    height: 1.1,
    letterSpacing: -1.0,
    fontWeight: FontWeight.w400,
  );
  static const displayMd = TextStyle(
    fontFamily: _displayFamily,
    fontSize: 36,
    height: 1.15,
    letterSpacing: -0.5,
    fontWeight: FontWeight.w400,
  );
  static const displaySm = TextStyle(
    fontFamily: _displayFamily,
    fontSize: 28,
    height: 1.2,
    letterSpacing: -0.3,
    fontWeight: FontWeight.w400,
  );

  static const titleLg = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 22,
    height: 1.3,
    fontWeight: FontWeight.w500,
  );
  static const titleMd = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 18,
    height: 1.4,
    fontWeight: FontWeight.w500,
  );
  static const titleSm = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 16,
    height: 1.4,
    fontWeight: FontWeight.w500,
  );

  static const bodyMd = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 16,
    height: 1.55,
    fontWeight: FontWeight.w400,
  );
  static const bodySm = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 14,
    height: 1.55,
    fontWeight: FontWeight.w400,
  );

  static const caption = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
  );
  static const captionUpper = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.2,
  );

  static const buttonLabel = TextStyle(
    fontFamily: _bodyFamily,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w500,
  );
}

/// 모션 토큰. 사용 시점에 추가하는 정책 — 미사용 토큰은 제거.
class CubbyMotion {
  static const immersive = Duration(milliseconds: 200);
  static const immersiveCurve = Curves.easeInOut;
}
