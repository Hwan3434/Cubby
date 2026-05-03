import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'grouping_unit.dart';

/// 앱 전역 환경설정. SharedPreferences로 영속화.
class AppPreferences {
  AppPreferences(this._prefs);

  final SharedPreferences _prefs;

  static const _kGrouping = 'grouping_unit_v1';
  static const _kFirstLaunch = 'first_launch_at_v1';
  static const _kThemeMode = 'theme_mode_v1';

  GroupingUnit get groupingUnit {
    final raw = _prefs.getString(_kGrouping);
    return GroupingUnit.values.firstWhere(
      (g) => g.name == raw,
      orElse: () => GroupingUnit.day,
    );
  }

  Future<void> setGroupingUnit(GroupingUnit unit) {
    return _prefs.setString(_kGrouping, unit.name);
  }

  /// 앱이 처음 실행된 시각. 누락이면 now()로 채움.
  DateTime get firstLaunchAt {
    final raw = _prefs.getInt(_kFirstLaunch);
    if (raw == null) return DateTime.now();
    return DateTime.fromMillisecondsSinceEpoch(raw);
  }

  Future<void> ensureFirstLaunchRecorded() async {
    if (_prefs.containsKey(_kFirstLaunch)) return;
    await _prefs.setInt(
      _kFirstLaunch,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  ThemeMode get themeMode {
    final raw = _prefs.getString(_kThemeMode);
    return ThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) {
    return _prefs.setString(_kThemeMode, mode.name);
  }
}

/// AppPreferences 비동기 로딩. 앱 부트 시점 1회.
final appPreferencesProvider = FutureProvider<AppPreferences>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final app = AppPreferences(prefs);
  await app.ensureFirstLaunchRecorded();
  return app;
});

/// 현재 ThemeMode. AppPreferences 로드 전엔 system이 기본.
class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final prefs = ref.watch(appPreferencesProvider).value;
    return prefs?.themeMode ?? ThemeMode.system;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = ref.read(appPreferencesProvider).value;
    await prefs?.setThemeMode(mode);
  }

  Future<void> cycle() async {
    final next = switch (state) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    await set(next);
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
