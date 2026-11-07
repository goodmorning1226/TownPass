import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/mock_pages/mock_page_scaffold.dart';
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Height of the in-page number keypad, above the safe area.
const waterKeypadHeight = 286.0;

/// Stand-in for the TownPass-Services water fee page, so the guide can be
/// tried without the WebView. Queries nothing; the result is a placeholder.
///
/// The water number is typed on an in-page keypad (as in the design) rather
/// than the system keyboard, so every phone has the same 完成 key.
class MockWaterFeeView extends StatefulWidget {
  const MockWaterFeeView({super.key});

  @override
  State<MockWaterFeeView> createState() => _MockWaterFeeViewState();
}

class _MockWaterFeeViewState extends State<MockWaterFeeView> {
  static const _teal = Color(0xFF36B5C6);
  static const _tealText = Color(0xFF2E9AAA);

  final _state = Get.find<MockServiceState>();
  bool _dialog = false;

  @override
  void dispose() {
    _state.waterFocused.value = false;
    super.dispose();
  }

  GuidedAssistantController? get _guide =>
      Get.isRegistered<GuidedAssistantController>()
      ? Get.find<GuidedAssistantController>()
      : null;

  void _openKeypad() {
    if (_state.waterQueried.value) return;
    _state.waterFieldTapped.value = true;
    _state.waterFocused.value = true;
  }

  void _press(String key) {
    final digits = _state.waterDigits.value;
    if (digits.length < MockServiceState.waterDigitCount) {
      _state.waterDigits.value = digits + key;
    }
  }

  void _delete() {
    final digits = _state.waterDigits.value;
    if (digits.isNotEmpty) {
      _state.waterDigits.value = digits.substring(0, digits.length - 1);
    }
  }

  void _done() {
    final missing =
        MockServiceState.waterDigitCount - _state.waterDigits.value.length;
    final guide = _guide;
    if (missing > 0 && guide != null && guide.locked) {
      guide.showNudge('水號有 10 碼，還差 $missing 碼喔。');
      return;
    }
    _state.waterFocused.value = false;
  }

  void _query() {
    _state.waterFocused.value = false;
    if (_state.waterDigits.value.length < MockServiceState.waterDigitCount) {
      setState(() => _dialog = true);
      return;
    }
    _state.waterQueried.value = true;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MockServiceScaffold(
          title: '水費',
          body: Obx(
            () => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _subHeader(),
                _tabs(),
                Expanded(
                  child: _state.waterQueried.value ? _result() : _form(),
                ),
              ],
            ),
          ),
          bottom: Obx(
            () => _state.waterQueried.value
                ? const SizedBox.shrink()
                : _bottomBar(),
          ),
        ),
        Obx(
          () => _state.waterFocused.value && !_state.waterQueried.value
              ? Positioned(left: 0, right: 0, bottom: 0, child: _keypad())
              : const SizedBox.shrink(),
        ),
        if (_dialog) _alert(),
      ],
    );
  }

  Widget _keypad() {
    final ready =
        _state.waterDigits.value.length == MockServiceState.waterDigitCount;
    final guiding = _guide?.locked ?? false;
    const keyStyle = TextStyle(
      fontSize: 22,
      height: 28 / 22,
      color: TPColors.grayscale950,
    );
    Widget key(
      Widget child, {
      required VoidCallback onTap,
      required String label,
      Color color = TPColors.white,
      BoxBorder? border,
    }) => Semantics(
      button: true,
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: border,
          boxShadow: color == TPColors.white
              ? const [
                  BoxShadow(color: TPColors.grayscale300, offset: Offset(0, 1)),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      ),
    );

    final keys = <Widget>[
      for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
        key(
          Text(d, style: keyStyle),
          onTap: () => _press(d),
          label: d,
        ),
      key(
        const Icon(Icons.backspace_outlined, color: TPColors.grayscale950),
        onTap: _delete,
        label: '刪除',
        color: TPColors.grayscale200,
      ),
      key(
        Text('0', style: keyStyle),
        onTap: () => _press('0'),
        label: '0',
      ),
      GuideTarget(
        id: 'water.done',
        child: key(
          const TPText(
            '完成',
            style: TPTextStyles.titleSemiBold,
            color: TPColors.white,
          ),
          onTap: _done,
          label: '完成',
          color: TPColors.primary700,
          border: ready && guiding
              ? Border.all(color: guideYellow, width: 3)
              : null,
        ),
      ),
    ];

    return GuideTarget(
      id: 'water.keypad',
      child: Material(
        color: TPColors.grayscale100,
        child: Container(
          height: waterKeypadHeight + MediaQuery.of(context).padding.bottom,
          color: TPColors.grayscale100,
          padding: EdgeInsets.fromLTRB(
            8,
            8,
            8,
            8 + MediaQuery.of(context).padding.bottom,
          ),
          child: Column(
            children: [
              SizedBox(
                height: 32,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      TPText(
                        '已輸入 ${_state.waterDigits.value.length} / '
                        '${MockServiceState.waterDigitCount} 碼',
                        style: TPTextStyles.h3Regular,
                        color: TPColors.grayscale800,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 3,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 2.4,
                  children: keys,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subHeader() => const SizedBox(
    height: 48,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 16,
          child: Icon(Icons.chevron_left_rounded, color: TPColors.grayscale950),
        ),
        TPText(
          '水費',
          style: TPTextStyles.titleSemiBold,
          color: TPColors.grayscale950,
        ),
        Positioned(right: 12, child: MockBadge()),
      ],
    ),
  );

  Widget _tabs() => Container(
    height: 46,
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: TPColors.grayscale100)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Container(
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _teal, width: 3)),
            ),
            child: const TPText(
              '輸入資料',
              style: TPTextStyles.h3SemiBold,
              color: _tealText,
            ),
          ),
        ),
        const Expanded(
          child: Center(
            child: TPText(
              '掃描',
              style: TPTextStyles.h3SemiBold,
              color: TPColors.grayscale950,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _form() {
    final digits = _state.waterDigits.value;
    final open = _state.waterFocused.value;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, open ? waterKeypadHeight : 24),
      children: [
        const TPText(
          '水號',
          style: TPTextStyles.titleSemiBold,
          color: TPColors.grayscale950,
        ),
        const SizedBox(height: 4),
        const TPText(
          '大區為1碼，中區為2碼，戶號為6碼，檢核號為1碼',
          style: TPTextStyles.bodyRegular,
          color: TPColors.grayscale400,
        ),
        const SizedBox(height: 12),
        GuideTarget(
          id: 'water.field',
          child: Semantics(
            button: true,
            label: '水號輸入框',
            value: digits,
            child: Material(
              color: TPColors.grayscale50,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: open
                    ? const BorderSide(color: _teal, width: 2)
                    : BorderSide.none,
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _openKeypad,
                child: Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      if (digits.isEmpty)
                        const TPText(
                          '請輸入水號',
                          style: TPTextStyles.h3Regular,
                          color: TPColors.grayscale400,
                        )
                      else
                        TPText(
                          digits,
                          style: TPTextStyles.h3Regular.copyWith(
                            letterSpacing: 1,
                          ),
                          color: TPColors.grayscale950,
                        ),
                      if (open)
                        Container(
                          width: 2,
                          height: 22,
                          margin: const EdgeInsets.only(left: 2),
                          color: _teal,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const TPText(
          '注意事項',
          style: TPTextStyles.h3Regular,
          color: TPColors.grayscale950,
        ),
        const SizedBox(height: 8),
        _bullet('若已在超商繳費、其他繳費平台或與銀行約定自動扣繳，請勿重複繳費。'),
        _bullet('即日起電子帳單用戶，以行動支付繳費（含本網站信用卡支付），下期水費減收10元（不限次數）。'),
      ],
    );
  }

  Widget _bullet(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TPText(
          '•  ',
          style: TPTextStyles.h3Regular,
          color: TPColors.grayscale950,
        ),
        Expanded(
          child: TPText(
            text,
            style: TPTextStyles.h3Regular,
            color: TPColors.grayscale950,
          ),
        ),
      ],
    ),
  );

  Widget _bottomBar() => Container(
    padding: EdgeInsets.fromLTRB(
      16,
      16,
      16,
      20 + MediaQuery.of(context).padding.bottom,
    ),
    decoration: const BoxDecoration(
      color: TPColors.white,
      boxShadow: [
        BoxShadow(
          color: Color(0x0F000000),
          blurRadius: 12,
          offset: Offset(0, -4),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TPText(
          '逾繳費期限，不提供查詢繳費功能',
          style: TPTextStyles.h3Regular,
          color: _tealText,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        GuideTarget(
          id: 'water.query',
          child: SizedBox(
            height: 48,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _teal,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _query,
              child: const TPText(
                '查詢',
                style: TPTextStyles.titleSemiBold,
                color: TPColors.white,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _result() => Align(
    alignment: Alignment.topCenter,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Container(
        height: 300,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          border: Border.all(color: TPColors.grayscale200, width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TPText(
              '查詢結果頁',
              style: TPTextStyles.titleSemiBold,
              color: TPColors.grayscale700,
            ),
            SizedBox(height: 8),
            TPText(
              '示範：這一頁的真實畫面尚未取得，帳單金額等資訊會顯示在這裡。',
              style: TPTextStyles.h3Regular,
              color: TPColors.grayscale700,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );

  Widget _alert() => Positioned.fill(
    child: ColoredBox(
      color: const Color(0x800B0D0E),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          decoration: BoxDecoration(
            color: TPColors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const TPText(
                '提醒',
                style: TPTextStyles.h2SemiBold,
                color: TPColors.grayscale950,
              ),
              const SizedBox(height: 12),
              const TPText(
                '請確認資料是否含空白或符號',
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale800,
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: TPColors.grayscale100),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  onPressed: () => setState(() => _dialog = false),
                  child: const TPText(
                    '確認',
                    style: TPTextStyles.h3Regular,
                    color: _tealText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
