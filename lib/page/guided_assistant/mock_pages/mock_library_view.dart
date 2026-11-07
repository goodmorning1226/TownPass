import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/guide_target.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/mock_pages/mock_page_scaffold.dart';
import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guide_highlight.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Height of the in-page keyboard on the search page, above the safe area.
const libraryKeyboardHeight = 260.0;

/// Stand-in for the library service (as in the design): home, keyword search
/// with an in-page keyboard, results, book detail, 取書館 window and the
/// 預約成功 window. Demo data only; nothing is reserved.
class MockLibraryView extends StatefulWidget {
  const MockLibraryView({super.key});

  @override
  State<MockLibraryView> createState() => _MockLibraryViewState();
}

class _MockLibraryViewState extends State<MockLibraryView> {
  static const _teal = Color(0xFF36B5C6);
  static const _tealText = Color(0xFF2E9AAA);
  static const _grey = Color(0xFF738995);

  final _s = Get.find<MockServiceState>();
  final _results = ScrollController();
  Timer? _closeList;

  @override
  void initState() {
    super.initState();
    _results.addListener(() {
      if (!_s.libraryScrolled.value && _results.offset > 24) {
        _s.libraryScrolled.value = true;
      }
    });
  }

  @override
  void dispose() {
    _closeList?.cancel();
    _results.dispose();
    _s.libraryKeyboard.value = false;
    super.dispose();
  }

  GuidedAssistantController? get _guide =>
      Get.isRegistered<GuidedAssistantController>()
      ? Get.find<GuidedAssistantController>()
      : null;

  bool get _guiding => _guide?.locked ?? false;

  void _openSearch() {
    _s.libraryPage.value = LibraryPage.search;
    _s.librarySearched.value = false;
    _s.libraryScrolled.value = false;
    _s.libraryKeyboard.value = false;
  }

  void _search() {
    if (_s.libraryQuery.value.trim().isEmpty) {
      if (_guiding) _guide!.showNudge(Replies.searchEmpty);
      return;
    }
    _s.librarySearched.value = true;
    _s.libraryScrolled.value = false;
    _s.libraryKeyboard.value = false;
  }

  void _pickBook(int i) {
    _s.libraryPage.value = LibraryPage.detail;
    _s.libraryBook.value = i;
    _s.libraryBranch.value = -1;
    _s.libraryScrolled.value = true;
    _s.libraryKeyboard.value = false;
  }

  void _pickBranch(int i) {
    _s.libraryBranch.value = i;
    _closeList?.cancel();
    _closeList = Timer(
      const Duration(milliseconds: 500),
      () => _s.libraryBranchList.value = false,
    );
  }

  void _reserve() {
    if (_s.libraryBranch.value < 0) {
      if (_guide?.task.value?.status == TaskStatus.on) {
        _guide!.showNudge(Replies.reserveNoBranch);
      }
      return;
    }
    _s.libraryReserved.value = true;
    _s.librarySuccess.value = true;
  }

  void _back() {
    if (_s.libraryPage.value == LibraryPage.detail) {
      _s.libraryPage.value = LibraryPage.search;
      _s.libraryBranchList.value = false;
    } else {
      _s.libraryPage.value = LibraryPage.home;
      _s.librarySearched.value = false;
      _s.libraryScrolled.value = false;
      _s.libraryKeyboard.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final page = _s.libraryPage.value;
      return Stack(
        children: [
          MockServiceScaffold(
            title: '圖書借閱',
            onBack: page == LibraryPage.home ? null : _back,
            body: switch (page) {
              LibraryPage.home => _home(),
              LibraryPage.search => _searchPage(),
              LibraryPage.detail => _detail(),
            },
            bottom: page == LibraryPage.detail ? _detailBottom() : null,
          ),
          if (page == LibraryPage.search && _s.libraryKeyboard.value)
            Positioned(left: 0, right: 0, bottom: 0, child: _keyboard()),
          if (_s.libraryBranchList.value && page == LibraryPage.detail)
            _branchWindow(),
          if (_s.librarySuccess.value) _successWindow(),
        ],
      );
    });
  }

  // ------------------------------------------------------------------ home

  Widget _home() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _tabs(const ['館藏查詢', '我的紀錄', '分館地圖']),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: GuideTarget(
          id: 'library.search_entry',
          child: Material(
            color: TPColors.grayscale50,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _openSearch,
              child: const SizedBox(
                height: 48,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded, color: TPColors.grayscale700),
                      SizedBox(width: 10),
                      TPText(
                        '關鍵字搜尋',
                        style: TPTextStyles.h3Regular,
                        color: TPColors.grayscale400,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 22, 16, 24),
          children: [
            const Align(alignment: Alignment.centerRight, child: MockBadge()),
            const TPText(
              '新書介紹',
              style: TPTextStyles.titleSemiBold,
              color: TPColors.grayscale950,
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final title in const [
                  '神奇柑仔店. 15, 冒牌的長髮公主',
                  '歡迎光臨錢天堂',
                  '底層邏輯',
                ]) ...[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _cover(130),
                        const SizedBox(height: 6),
                        TPText(
                          title,
                          style: TPTextStyles.h3Regular,
                          color: TPColors.grayscale950,
                        ),
                      ],
                    ),
                  ),
                  if (title != '底層邏輯') const SizedBox(width: 12),
                ],
              ],
            ),
            const SizedBox(height: 24),
            const Row(
              children: [
                Expanded(
                  child: TPText(
                    '點閱排行',
                    style: TPTextStyles.titleSemiBold,
                    color: TPColors.grayscale950,
                  ),
                ),
                TPText('更多', style: TPTextStyles.h3Regular, color: _tealText),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 20,
                  child: TPText(
                    '1',
                    style: TPTextStyles.titleSemiBold,
                    color: TPColors.grayscale950,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(width: 64, child: _cover(84)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TPText(
                        '底層邏輯 : 看清這個世界的底牌',
                        style: TPTextStyles.h3Regular,
                        color: TPColors.grayscale950,
                      ),
                      TPText(
                        '點閱次數：示意資料',
                        style: TPTextStyles.bodyRegular,
                        color: _grey,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );

  // ---------------------------------------------------------------- search

  Widget _searchPage() {
    final query = _s.libraryQuery.value;
    final open = _s.libraryKeyboard.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: GuideTarget(
            id: 'library.search_row',
            child: Row(
              children: [
                Container(
                  width: 88,
                  height: 48,
                  decoration: BoxDecoration(
                    color: TPColors.grayscale50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TPText(
                        '全部',
                        style: TPTextStyles.h3Regular,
                        color: TPColors.grayscale950,
                      ),
                      Icon(Icons.expand_more_rounded, size: 20),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: '輸入書名或關鍵字',
                    value: query,
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
                        onTap: () => _s.libraryKeyboard.value = true,
                        child: Container(
                          height: 48,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              Flexible(
                                child: TPText(
                                  query.isEmpty ? '輸入關鍵字' : query,
                                  style: TPTextStyles.h3Regular,
                                  color: query.isEmpty
                                      ? TPColors.grayscale400
                                      : TPColors.grayscale950,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
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
                const SizedBox(width: 4),
                Semantics(
                  button: true,
                  label: '搜尋',
                  child: Material(
                    color: _teal,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _search,
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.search_rounded,
                          color: TPColors.white,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _s.librarySearched.value ? _resultList() : _hotWords()),
      ],
    );
  }

  Widget _hotWords() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
    children: [
      const TPText(
        '熱門關鍵字',
        style: TPTextStyles.h3SemiBold,
        color: TPColors.grayscale950,
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final word in const [
            '神奇柑仔店',
            '東野圭吾',
            '小說',
            '如果歷史是一群喵',
            '漫畫',
            '哈利波特',
          ])
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: TPColors.grayscale50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TPText(
                word,
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale950,
              ),
            ),
        ],
      ),
    ],
  );

  Widget _resultList() {
    const books = MockServiceState.libraryBooks;
    return ListView.builder(
      controller: _results,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      itemCount: books.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return SizedBox(
            height: 28,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TPText(
                '「${_s.libraryQuery.value.trim()}」的搜尋結果（示意資料）',
                style: TPTextStyles.bodyRegular,
                color: TPColors.grayscale700,
              ),
            ),
          );
        }
        final (title, author) = books[i - 1];
        return InkWell(
          onTap: () => _pickBook(i - 1),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: TPColors.grayscale100)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 60, child: _cover(84)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TPText(
                        title,
                        style: TPTextStyles.h3Regular,
                        color: TPColors.grayscale950,
                      ),
                      TPText(
                        '著者：$author',
                        style: TPTextStyles.h3Regular,
                        color: _grey,
                      ),
                      const TPText(
                        '出版項：示意資料',
                        style: TPTextStyles.h3Regular,
                        color: _grey,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _keyboard() {
    final bottom = MediaQuery.of(context).padding.bottom;
    final ready =
        _s.libraryQuery.value.trim().isNotEmpty && (_guide?.locked ?? false);
    Widget key(
      Widget child,
      VoidCallback onTap, {
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

    return GuideTarget(
      id: 'library.keyboard',
      child: Material(
        color: TPColors.grayscale100,
        child: Container(
          height: libraryKeyboardHeight + bottom,
          padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottom),
          child: Column(
            children: [
              const SizedBox(
                height: 24,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TPText(
                      '選字（示範鍵盤）',
                      style: TPTextStyles.bodyRegular,
                      color: TPColors.grayscale700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    for (final (i, word) in const [
                      '小王子',
                      '小說',
                      '小丸子',
                    ].indexed) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Expanded(
                        child: key(
                          TPText(
                            word,
                            style: TPTextStyles.titleSemiBold.copyWith(
                              fontWeight: FontWeight.w400,
                            ),
                            color: TPColors.grayscale950,
                          ),
                          () => _s.libraryQuery.value = word == '小說'
                              ? '${_s.libraryQuery.value}小說'
                              : word,
                          label: word,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 6),
              // Zhuyin keys are drawn for the look only (demo keyboard).
              Expanded(
                child: ExcludeSemantics(
                  child: GridView.count(
                    crossAxisCount: 6,
                    mainAxisSpacing: 5,
                    crossAxisSpacing: 5,
                    padding: EdgeInsets.zero,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 1.9,
                    children: [
                      for (final z in 'ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐ'.split(''))
                        Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: TPColors.grayscale50,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: TPText(
                            z,
                            style: TPTextStyles.h3Regular,
                            color: _grey,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    Expanded(
                      child: key(
                        const Icon(
                          Icons.backspace_outlined,
                          color: TPColors.grayscale950,
                        ),
                        () {
                          final q = _s.libraryQuery.value;
                          if (q.isNotEmpty) {
                            _s.libraryQuery.value = q.substring(
                              0,
                              q.length - 1,
                            );
                          }
                        },
                        label: '刪除',
                        color: TPColors.grayscale200,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      flex: 2,
                      child: key(
                        const TPText(
                          '空白',
                          style: TPTextStyles.h3Regular,
                          color: TPColors.grayscale700,
                        ),
                        () =>
                            _s.libraryQuery.value = '${_s.libraryQuery.value} ',
                        label: '空白',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: key(
                        const TPText(
                          '搜尋',
                          style: TPTextStyles.titleSemiBold,
                          color: TPColors.white,
                        ),
                        _search,
                        label: '搜尋',
                        color: TPColors.primary700,
                        border: ready
                            ? Border.all(color: guideYellow, width: 3)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- detail

  Widget _detail() {
    final i = _s.libraryBook.value;
    final (title, author) = i < 0 ? ('', '') : MockServiceState.libraryBooks[i];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 100, child: _cover(140)),
            const SizedBox(width: 16),
            Expanded(
              child: TPText(
                title,
                style: TPTextStyles.titleSemiBold.copyWith(
                  fontWeight: FontWeight.w400,
                ),
                color: TPColors.grayscale950,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        TPText(
          '著者：$author',
          style: TPTextStyles.h3Regular,
          color: TPColors.grayscale950,
        ),
        const TPText(
          '出版項：示意資料',
          style: TPTextStyles.h3Regular,
          color: TPColors.grayscale950,
        ),
        const TPText(
          'ISBN：示意資料',
          style: TPTextStyles.h3Regular,
          color: TPColors.grayscale950,
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1, color: TPColors.grayscale100),
        ),
        Row(
          children: [
            const Expanded(
              child: TPText(
                '預約等待人數：12（示意）',
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale950,
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF6E9E2E),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const TPText(
                '熱門館藏',
                style: TPTextStyles.bodySemiBold,
                color: TPColors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _detailBottom() {
    final chosen = _s.libraryBranch.value >= 0;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        color: TPColors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
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
            '取書館',
            style: TPTextStyles.titleSemiBold,
            color: TPColors.grayscale950,
          ),
          const SizedBox(height: 8),
          GuideTarget(
            id: 'library.branch_field',
            child: Material(
              color: TPColors.grayscale50,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _s.libraryBranchList.value = true,
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: TPText(
                            chosen ? _s.branchName : '請選擇取書館',
                            style: TPTextStyles.h3Regular,
                            color: chosen
                                ? TPColors.grayscale950
                                : TPColors.grayscale800,
                          ),
                        ),
                        const Icon(Icons.expand_more_rounded),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          GuideTarget(
            id: 'library.reserve',
            child: SizedBox(
              height: 48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: chosen ? _teal : TPColors.grayscale200,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _reserve,
                child: TPText(
                  '預約',
                  style: TPTextStyles.h3Regular,
                  color: chosen ? TPColors.white : TPColors.grayscale800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _branchWindow() => Positioned.fill(
    child: Material(
      color: const Color(0x660B0D0E),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 44),
          height: 440,
          decoration: BoxDecoration(
            color: TPColors.white,
            borderRadius: BorderRadius.circular(6),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    const Expanded(
                      child: TPText(
                        '請選擇取書館',
                        style: TPTextStyles.titleSemiBold,
                        color: TPColors.grayscale950,
                      ),
                    ),
                    IconButton(
                      tooltip: '關閉選單',
                      onPressed: () => _s.libraryBranchList.value = false,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _tabs(const ['離我最近', '依行政區選擇'], height: 44),
              ),
              Expanded(
                child: GuideTarget(
                  id: 'library.branch_list',
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final (i, (name, dist))
                          in MockServiceState.libraryBranches.indexed)
                        _branchRow(i, name, dist),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _branchRow(int i, String name, String dist) {
    final selected = _s.libraryBranch.value == i;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: () => _pickBranch(i),
        child: Container(
          height: 52,
          color: selected ? TPColors.primary50 : null,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TPText(
                  name,
                  style: selected
                      ? TPTextStyles.h3SemiBold
                      : TPTextStyles.h3Regular,
                  color: selected ? TPColors.primary800 : TPColors.grayscale950,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (selected)
                const Icon(Icons.check_rounded, color: _tealText)
              else
                TPText(
                  dist,
                  style: TPTextStyles.h3Regular,
                  color: TPColors.grayscale700,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _successWindow() => Positioned.fill(
    child: Material(
      color: const Color(0x660B0D0E),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 44),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          decoration: BoxDecoration(
            color: TPColors.white,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: TPColors.secondary100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const TPText(
                    '示範畫面，未真的送出',
                    style: TPTextStyles.bodyRegular,
                    color: TPColors.secondary800,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: TPColors.primary500,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: TPColors.white,
                  size: 40,
                ),
              ),
              const SizedBox(height: 12),
              const TPText(
                '預約成功',
                style: TPTextStyles.h2SemiBold,
                color: TPColors.grayscale950,
              ),
              const SizedBox(height: 8),
              TPText(
                '本次預約成功 1 筆\n取書館：${_s.branchName}\n到館通知：目前無通知。',
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale800,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Divider(height: 1, color: TPColors.grayscale100),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () {
                        _s.librarySuccess.value = false;
                        _s.libraryPage.value = LibraryPage.home;
                      },
                      child: const TPText(
                        '返回首頁',
                        style: TPTextStyles.h3SemiBold,
                        color: TPColors.grayscale700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => _s.librarySuccess.value = false,
                      child: const TPText(
                        '查看預約清單',
                        style: TPTextStyles.h3SemiBold,
                        color: _tealText,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  // ---------------------------------------------------------------- shared

  Widget _tabs(List<String> labels, {double height = 48}) => Container(
    height: height,
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: TPColors.grayscale100)),
    ),
    child: Row(
      children: [
        for (final (i, label) in labels.indexed)
          Expanded(
            child: Container(
              alignment: Alignment.center,
              decoration: i == 0
                  ? const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: _teal, width: 3),
                      ),
                    )
                  : null,
              child: TPText(
                label,
                style: TPTextStyles.h3SemiBold,
                color: i == 0 ? _tealText : TPColors.grayscale950,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _cover(double height) => Container(
    height: height,
    decoration: BoxDecoration(
      color: TPColors.grayscale100,
      borderRadius: BorderRadius.circular(4),
    ),
  );
}
