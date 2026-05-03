import 'package:photo_manager/photo_manager.dart';

import '../../data/grouping_unit.dart';

export '../../data/grouping_unit.dart' show GroupingUnit;

class AssetSection {
  AssetSection({required this.label, required this.items});
  final String label;
  final List<AssetEntity> items;
}

/// items는 정렬 상태 그대로(내림차/오름차 무관) 받아 같은 그룹 키를 가진 연속
/// 자산을 한 섹션으로 묶는다. "오늘"/"어제"는 단위와 무관하게 항상 day 단위
/// 라벨로 나뉘고, 그 외에만 [unit]이 적용된다.
List<AssetSection> groupAssets(
  List<AssetEntity> items,
  GroupingUnit unit, {
  DateTime? now,
}) {
  if (items.isEmpty) return const [];
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final yesterday = today.subtract(const Duration(days: 1));

  final sections = <AssetSection>[];
  String? currentKey;
  String? currentLabel;
  List<AssetEntity> bucket = [];

  void flush() {
    if (bucket.isEmpty) return;
    sections.add(AssetSection(label: currentLabel!, items: bucket));
    bucket = [];
  }

  for (final item in items) {
    final created = item.createDateTime;
    final day = DateTime(created.year, created.month, created.day);
    String key;
    String label;
    if (day == today) {
      key = 'today';
      label = '오늘';
    } else if (day == yesterday) {
      key = 'yesterday';
      label = '어제';
    } else {
      switch (unit) {
        case GroupingUnit.day:
          key = 'd:${day.toIso8601String()}';
          label = _formatDayLabel(day, ref);
        case GroupingUnit.week:
          final weekStart = _weekStartMonday(day);
          key = 'w:${weekStart.toIso8601String()}';
          label = _formatWeekLabel(weekStart, today);
        case GroupingUnit.month:
          key = 'm:${day.year}-${day.month}';
          label = _formatMonthLabel(day, ref);
      }
    }

    if (currentKey != key) {
      flush();
      currentKey = key;
      currentLabel = label;
    }
    bucket.add(item);
  }
  flush();
  return sections;
}

String _formatDayLabel(DateTime day, DateTime now) {
  if (day.year == now.year) return '${day.month}월 ${day.day}일';
  return '${day.year}년 ${day.month}월 ${day.day}일';
}

DateTime _weekStartMonday(DateTime d) {
  final daysFromMonday = (d.weekday - DateTime.monday) % 7;
  return DateTime(d.year, d.month, d.day)
      .subtract(Duration(days: daysFromMonday));
}

String _formatWeekLabel(DateTime weekStart, DateTime today) {
  final thisWeekStart = _weekStartMonday(today);
  final diffWeeks = thisWeekStart.difference(weekStart).inDays ~/ 7;
  final weekEnd = weekStart.add(const Duration(days: 6));
  final range = _formatWeekRange(weekStart, weekEnd);
  if (diffWeeks <= 0) return '이번 주 ($range)';
  if (diffWeeks == 1) return '지난 주 ($range)';
  return '$diffWeeks주 전 ($range)';
}

String _formatWeekRange(DateTime start, DateTime end) {
  if (start.year == end.year && start.month == end.month) {
    return '${start.month}월 ${start.day}~${end.day}일';
  }
  return '${start.month}월 ${start.day}일~${end.month}월 ${end.day}일';
}

String _formatMonthLabel(DateTime day, DateTime now) {
  if (day.year == now.year) return '${day.month}월';
  return '${day.year}년 ${day.month}월';
}
