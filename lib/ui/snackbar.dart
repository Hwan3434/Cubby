import 'package:flutter/material.dart';

import 'theme/cubby_theme.dart';

/// 에러용 SnackBar. coral primary나 cubby.danger 같은 강조색 대신
/// 시스템 ColorScheme.error를 사용해 OS 일관성 유지.
void showError(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: scheme.onError),
        ),
        backgroundColor: scheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
}

/// 정보용 SnackBar. cream surface 톤으로 차분하게.
void showInfo(BuildContext context, String message) {
  final cubby = context.cubby;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: cubby.bodyStrong),
        ),
        backgroundColor: cubby.surfaceCreamStrong,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
}
