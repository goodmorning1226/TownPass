import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_bottom_navigation_factory.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_setting_list.dart';
import 'package:town_pass/util/tp_text.dart';
import 'package:town_pass/util/tp_web_view.dart';
import 'package:townpass_portal_assistant/townpass_portal_assistant.dart';

/// TownPass as the portal assistant's host (PortalAssistantHost): its routes,
/// WebView page, first-page tabs and app bar. Registered in main.dart with
/// PortalAssistant.init; portal_assistant/INTEGRATION.md lists every hook.
class TownPassAssistantHost extends PortalAssistantHost {
  const TownPassAssistantHost();

  @override
  String get mainRoute => TPRoute.main;

  @override
  String get webViewRoute => TPRoute.webView;

  @override
  bool hasRoute(String route) => TPRoute.page.any((page) => page.name == route);

  @override
  Future<void>? openWebView({
    required String url,
    required String title,
    required AssistantWebRequest request,
  }) => Get.toNamed<void>(
    TPRoute.webView,
    preventDuplicates: false,
    arguments: WebViewArgument(url: url, forceTitle: title, assistant: request),
  );

  @override
  RxInt? get mainTab => Get.isRegistered<MainViewController>()
      ? Get.find<MainViewController>().currentIndex
      : null;

  @override
  int get homeTab => TPBottomNavigationFactory.defaultIndex;

  @override
  PreferredSizeWidget appBar({required String title}) => TPAppBar(title: title);

  /// AI 助理設定 (new) on the account page (AccountView), followed by a space,
  /// while the guided assistant runs: its mode and language.
  static List<TPSettingListTile> accountTiles() {
    if (!PortalAssistant.guidedAvailable) return const [];
    final assistant = PortalAssistant.guided;
    return [
      TPSettingListTile.listTile(
        onTap: () => assistant.openSettingsPage(),
        title: const Row(
          children: [
            Flexible(
              child: TPText(
                SettingsTexts.title,
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale700,
              ),
            ),
            SizedBox(width: 8),
            SettingsTag(SettingsTexts.newTag),
          ],
        ),
        content: TPText(
          assistant.settingsSummary,
          style: TPTextStyles.bodyRegular,
          color: TPColors.grayscale500,
        ),
        trailing: Assets.svg.iconExpand.svg(),
      ),
      TPSettingListTile.space(),
    ];
  }
}
