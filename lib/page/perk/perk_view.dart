import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';
import 'package:townpass_portal_assistant/townpass_portal_assistant.dart';

class PerkView extends StatelessWidget {
  const PerkView({super.key});

  /// This page's tab on the App's first page (TPBottomNavigationFactory).
  static const tabIndex = 2;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: TPAppBar(
        showLogo: true,
        title: '優惠',
        leading: IconButton(
          icon: Semantics(
            label: '帳戶',
            child: Assets.svg.iconPerson.svg(),
          ),
          onPressed: () => Get.toNamed(TPRoute.account),
        ),
        actions: [
          IconButton(
            icon: Semantics(
              label: '票夾',
              child: Assets.svg.iconCouponTicket.svg(),
            ),
            onPressed: () async => await TPRoute.openUri(
              uri: 'https://taipei-pass-service.vercel.app/ticket-wallet',
            ),
          ),
        ],
      ),
      // Portal assistant: lets the guided assistant read this tab's page (read only).
      body: AssistantTabWebPage(
        tabIndex: tabIndex,
        builder: (page) => TPInAppWebView(
        key: page.viewKey,
        onWebViewCreated: (controller) {
          page.controller = controller;
          controller.loadUrl(
            urlRequest: URLRequest(url: WebUri('https://taipei-pass-service.vercel.app/coupon/')),
          );
        },
        onLoadStop: (_, url) => page.track(url),
        onUpdateVisitedHistory: (_, url, _) => page.track(url),
      ),
      ),
    );
  }
}
