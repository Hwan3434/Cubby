import 'package:flutter/material.dart';

import '../theme/cubby_theme.dart';
import '../theme/cubby_tokens.dart';

class NewAlbumResult {
  const NewAlbumResult({required this.name, required this.shootImmediately});
  final String name;
  final bool shootImmediately;
}

/// 모달 시트 진입점. 결과(이름 + "곧바로 촬영" 여부)는 Navigator.pop으로 반환.
Future<NewAlbumResult?> showNewAlbumSheet(BuildContext context) {
  return showModalBottomSheet<NewAlbumResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _NewAlbumSheet(),
  );
}

class _NewAlbumSheet extends StatefulWidget {
  const _NewAlbumSheet();

  @override
  State<_NewAlbumSheet> createState() => _NewAlbumSheetState();
}

class _NewAlbumSheetState extends State<_NewAlbumSheet> {
  final _controller = TextEditingController();
  String _name = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit({required bool shoot}) {
    final n = _controller.text.trim();
    if (n.isEmpty) return;
    Navigator.of(context)
        .pop(NewAlbumResult(name: n, shootImmediately: shoot));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final homeIndicator = MediaQuery.viewPaddingOf(context).bottom;
    // 키보드가 떠 있으면 home indicator 영역도 키보드가 가려 그 만큼만 띄우면
    // 충분. 키보드 없을 땐 home indicator/제스처 바 위로 컨텐츠가 닿지 않게
    // 그 영역만큼 padding.
    final bottomSafe = keyboard > 0 ? 0.0 : homeIndicator;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Container(
        decoration: BoxDecoration(
          color: cubby.canvas,
          borderRadius: const BorderRadius.only(
            topLeft: CubbyRadius.xxl,
            topRight: CubbyRadius.xxl,
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          CubbySpacing.lg,
          12,
          CubbySpacing.lg,
          28 + bottomSafe,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cubby.hairline,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
            const SizedBox(height: CubbySpacing.md),
            Text(
              '새 앨범',
              style: CubbyType.displaySm.copyWith(
                fontSize: 24,
                letterSpacing: -0.3,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '이름을 짓고, 곧바로 촬영을 시작합니다.',
              style: CubbyType.caption.copyWith(color: cubby.muted),
            ),
            const SizedBox(height: CubbySpacing.md),
            _NameField(
              controller: _controller,
              onChanged: (v) => setState(() => _name = v.trim()),
            ),
            const SizedBox(height: 6),
            Text(
              '앨범 이름은 중복될 수 없어요.',
              style: CubbyType.caption.copyWith(color: cubby.muted),
            ),
            const SizedBox(height: CubbySpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      side: BorderSide(color: cubby.hairline),
                      foregroundColor: scheme.onSurface,
                      shape: const RoundedRectangleBorder(
                        borderRadius: CubbyRadius.lgAll,
                      ),
                      textStyle: CubbyType.buttonLabel,
                    ),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _name.isEmpty ? null : () => _submit(shoot: true),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(48),
                      shape: const RoundedRectangleBorder(
                        borderRadius: CubbyRadius.lgAll,
                      ),
                      textStyle: CubbyType.buttonLabel,
                    ),
                    child: const Text('만들고 촬영'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NameField extends StatelessWidget {
  const _NameField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    const coralActive = Color(0xFFA9583E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cubby.canvas,
        borderRadius: CubbyRadius.lgAll,
        border: Border.all(color: scheme.primary, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.15),
            blurRadius: 0,
            spreadRadius: 3,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '이름',
            style: CubbyType.captionUpper.copyWith(
              fontSize: 11,
              color: coralActive,
            ),
          ),
          TextField(
            controller: controller,
            autofocus: true,
            onChanged: onChanged,
            textInputAction: TextInputAction.done,
            style: CubbyType.bodyMd.copyWith(
              fontSize: 18,
              color: scheme.onSurface,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.only(top: 4),
              hintText: '앨범명을 지어주세요',
              hintStyle: CubbyType.bodyMd.copyWith(
                fontSize: 18,
                color: cubby.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
