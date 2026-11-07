import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/mock_pages/mock_page_scaffold.dart';
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Stand-in for the library book detail page. The reservation is not sent
/// anywhere.
class MockLibraryBookView extends StatelessWidget {
  const MockLibraryBookView({super.key});

  static const volumes = ['第 1 冊', '第 2 冊', '第 3 冊'];
  static const branches = ['總館', '大安分館', '信義分館'];

  @override
  Widget build(BuildContext context) {
    final s = Get.find<MockServiceState>();
    return MockServiceScaffold(
      title: '圖書借閱',
      body: Obx(
        () => ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            120 + MediaQuery.of(context).padding.bottom,
          ),
          children: [
            const Align(alignment: Alignment.centerRight, child: MockBadge()),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 84,
                  height: 116,
                  decoration: BoxDecoration(
                    color: TPColors.primary100,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: const TPText(
                    '書封',
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.primary700,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TPText(
                        '底層邏輯',
                        style: TPTextStyles.h2SemiBold,
                        color: TPColors.grayscale950,
                      ),
                      SizedBox(height: 4),
                      TPText(
                        '示範書目',
                        style: TPTextStyles.h3Regular,
                        color: TPColors.grayscale700,
                      ),
                      SizedBox(height: 8),
                      TPText(
                        '館藏 3 本，可預約',
                        style: TPTextStyles.bodyRegular,
                        color: TPColors.primary700,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            GuideTarget(
              id: 'library.volume',
              child: _Selector(
                label: '冊次',
                options: volumes,
                value: s.libraryVolume.value,
                enabled: !s.libraryReserved.value,
                onChanged: (v) => s.libraryVolume.value = v,
              ),
            ),
            const SizedBox(height: 16),
            GuideTarget(
              id: 'library.branch',
              child: _Selector(
                label: '取書館',
                options: branches,
                value: s.libraryBranch.value,
                enabled: !s.libraryReserved.value,
                onChanged: (v) => s.libraryBranch.value = v,
              ),
            ),
            const SizedBox(height: 24),
            if (s.libraryReserved.value)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: TPColors.primary50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: TPText(
                  '已預約 ${s.libraryVolume.value}，到 ${s.libraryBranch.value} 取書。'
                  '（示範：沒有真的送出）',
                  style: TPTextStyles.h3Regular,
                  color: TPColors.primary800,
                ),
              )
            else
              GuideTarget(
                id: 'library.reserve',
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: TPColors.primary500,
                      disabledBackgroundColor: TPColors.grayscale100,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed:
                        s.libraryVolume.value != null &&
                            s.libraryBranch.value != null
                        ? () => s.libraryReserved.value = true
                        : null,
                    child: TPText(
                      '預約',
                      style: TPTextStyles.h3Regular,
                      color:
                          s.libraryVolume.value != null &&
                              s.libraryBranch.value != null
                          ? TPColors.white
                          : TPColors.grayscale500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A choice that opens inline (not as a popup route), so the guide's
/// highlight grows with the open list and the user can still pick from it
/// while the rest of the screen is locked.
class _Selector extends StatefulWidget {
  final String label;
  final List<String> options;
  final String? value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _Selector({
    required this.label,
    required this.options,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  State<_Selector> createState() => _SelectorState();
}

class _SelectorState extends State<_Selector> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TPColors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _open ? TPColors.primary500 : TPColors.grayscale200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.enabled ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  TPText(
                    '${widget.label}：',
                    style: TPTextStyles.h3SemiBold,
                    color: TPColors.grayscale800,
                  ),
                  Expanded(
                    child: TPText(
                      widget.value ?? '請選擇',
                      style: TPTextStyles.h3Regular,
                      color: widget.value == null
                          ? TPColors.grayscale400
                          : TPColors.grayscale950,
                    ),
                  ),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: TPColors.grayscale700,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            for (final option in widget.options)
              InkWell(
                onTap: () {
                  setState(() => _open = false);
                  widget.onChanged(option);
                },
                child: Container(
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  decoration: const BoxDecoration(
                    border: Border(
                      top: BorderSide(color: TPColors.grayscale100),
                    ),
                  ),
                  child: TPText(
                    option,
                    style: TPTextStyles.h3Regular,
                    color: option == widget.value
                        ? TPColors.primary700
                        : TPColors.grayscale950,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
