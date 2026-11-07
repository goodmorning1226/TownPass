import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Native title bar in the style of the WebView service pages: teal bar,
/// centred title, close button on the right.
class MockServiceScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final Widget? bottom;

  /// Shows a back button on the left (pages inside the service).
  final VoidCallback? onBack;

  const MockServiceScaffold({
    super.key,
    required this.title,
    required this.body,
    this.bottom,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TPColors.white,
      appBar: AppBar(
        backgroundColor: TPColors.primary500,
        automaticallyImplyLeading: false,
        leading: onBack == null
            ? null
            : IconButton(
                tooltip: '返回上一頁',
                onPressed: onBack,
                icon: const Icon(
                  Icons.chevron_left_rounded,
                  color: TPColors.white,
                  size: 32,
                ),
              ),
        toolbarHeight: 56,
        title: TPText(
          title,
          style: TPTextStyles.titleSemiBold,
          color: TPColors.white,
        ),
        actions: [
          IconButton(
            tooltip: '關閉$title',
            iconSize: 24,
            onPressed: Get.back,
            icon: const Icon(Icons.close_rounded, color: TPColors.white),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: bottom,
    );
  }
}

/// Small "demo" badge so nobody mistakes the mock pages for real services.
class MockBadge extends StatelessWidget {
  const MockBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: TPColors.secondary100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const TPText(
        '示範頁面',
        style: TPTextStyles.bodyRegular,
        color: TPColors.secondary800,
      ),
    );
  }
}
