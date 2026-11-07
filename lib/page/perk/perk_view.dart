import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/service/assistant_page_tracker.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';

class PerkView extends StatefulWidget {
  const PerkView({super.key});

  /// This page's tab on the App's first page (TPBottomNavigationFactory).
  static const tabIndex = 2;

  @override
  State<PerkView> createState() => _PerkViewState();
}

class _PerkViewState extends State<PerkView> {
  /// Lets the guided assistant read this tab's page (read only), as
  /// TPWebView does; it is the visible page only while this tab shows.
  final AssistantWebPage trackedPage = AssistantPageTracker.instance.attachTab(
    PerkView.tabIndex,
  );

  void _track(WebUri? url) =>
      trackedPage.url = url == null ? null : Uri.tryParse(url.toString());

  @override
  void dispose() {
    trackedPage.detach();
    super.dispose();
  }

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
      body: TPInAppWebView(
        key: trackedPage.viewKey,
        onWebViewCreated: (controller) {
          trackedPage.controller = controller;
          controller.loadUrl(
            urlRequest: URLRequest(url: WebUri('https://taipei-pass-service.vercel.app/coupon/')),
          );
        },
        onLoadStop: (_, url) => _track(url),
        onUpdateVisitedHistory: (_, url, _) => _track(url),
      ),
    );
  }
}
