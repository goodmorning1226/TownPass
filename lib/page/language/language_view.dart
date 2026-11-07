import 'package:town_pass/page/language/language_view_controller.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:town_pass/util/tp_setting_list.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class LanguageView extends GetView<LanguageViewController> {
  const LanguageView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TPColors.white,
      appBar: const TPAppBar(title: '語言'),
      body: TPSettingList(
        children: [
          TPSettingListTile.selectionList(
            initialIndex: controller.currentIndex,
            onIndexChange: (index) => controller.onIndexChange(index),
            selections: _buildLanguageSelections(),
          ),
        ],
      ),
    );
  }

  /// Each language named in its own script (PageTranslation.languages).
  List<SettingSelectionListItem> _buildLanguageSelections() {
    return controller.languageList
        .map<SettingSelectionListItem>(
          (code) =>
              SettingSelectionListItem(title: PageTranslation.languages[code]!),
        )
        .toList();
  }
}
