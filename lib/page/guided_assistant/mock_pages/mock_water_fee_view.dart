import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/mock_pages/mock_page_scaffold.dart';
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Stand-in for the TownPass-Services water fee page, so the guide can be
/// tried without the WebView. Queries nothing; the result is a placeholder.
class MockWaterFeeView extends StatefulWidget {
  const MockWaterFeeView({super.key});

  @override
  State<MockWaterFeeView> createState() => _MockWaterFeeViewState();
}

class _MockWaterFeeViewState extends State<MockWaterFeeView> {
  static const _teal = Color(0xFF36B5C6);
  static const _tealText = Color(0xFF2E9AAA);

  final _state = Get.find<MockServiceState>();
  late final _text = TextEditingController(text: _state.waterDigits.value);
  final _focus = FocusNode();
  bool _dialog = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      _state.waterFocused.value = _focus.hasFocus;
      if (_focus.hasFocus) _state.waterFieldTapped.value = true;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _state.waterFocused.value = false;
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _query() {
    _focus.unfocus();
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
        if (_dialog) _alert(),
      ],
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

  Widget _form() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
          label: '水號輸入框',
          child: TextField(
            controller: _text,
            focusNode: _focus,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(
                MockServiceState.waterDigitCount,
              ),
            ],
            onChanged: (v) => _state.waterDigits.value = v,
            onTap: () => _state.waterFieldTapped.value = true,
            onSubmitted: (_) => _focus.unfocus(),
            style: TPTextStyles.h3Regular.copyWith(
              color: TPColors.grayscale950,
              letterSpacing: 1,
            ),
            decoration: InputDecoration(
              hintText: '請輸入水號',
              hintStyle: TPTextStyles.h3Regular.copyWith(
                color: TPColors.grayscale400,
              ),
              filled: true,
              fillColor: TPColors.grayscale50,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 13,
              ),
              counterText: '',
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _teal, width: 2),
              ),
            ),
          ),
        ),
      ),
      if (_focus.hasFocus)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Obx(
            () => TPText(
              '已輸入 ${_state.waterDigits.value.length} / ${MockServiceState.waterDigitCount} 碼',
              style: TPTextStyles.bodyRegular,
              color: TPColors.grayscale800,
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
