import 'package:flutter/material.dart';

/// 보더 + 안쪽 padding + 라운드 클립으로 child를 감싸는 정사각형 셀.
/// 카메라의 최근 촬영 썸네일, 풀스크린 인디케이터 셀처럼 "보더가 child를
/// 가리지 않도록 안쪽으로 밀어 넣는" 케이스에 사용.
class BorderedThumb extends StatelessWidget {
  const BorderedThumb({
    super.key,
    required this.size,
    required this.borderColor,
    required this.borderWidth,
    required this.outerRadius,
    required this.child,
    this.fillColor,
  });

  final double size;
  final Color borderColor;
  final double borderWidth;
  final double outerRadius;
  final Color? fillColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final innerRadius = (outerRadius - borderWidth).clamp(0.0, outerRadius);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(borderWidth),
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.all(Radius.circular(outerRadius)),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(innerRadius)),
        child: child,
      ),
    );
  }
}
