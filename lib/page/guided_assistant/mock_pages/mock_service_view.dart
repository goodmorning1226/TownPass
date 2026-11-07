import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/guided_assistant/mock_pages/mock_page_scaffold.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// Placeholder for a service that is opened but has no guide yet.
class MockServiceView extends StatelessWidget {
  const MockServiceView({super.key});

  @override
  Widget build(BuildContext context) {
    final title = Get.arguments is String ? Get.arguments as String : '服務';
    return MockServiceScaffold(
      title: title,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Align(alignment: Alignment.centerRight, child: MockBadge()),
            const SizedBox(height: 40),
            TPText(
              '這是「$title」頁（示範）。\n這個功能還沒有逐步引導。',
              style: TPTextStyles.h3Regular,
              color: TPColors.grayscale700,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
