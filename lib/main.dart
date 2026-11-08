import 'dart:async';

import 'package:flutter/material.dart';
import 'package:town_pass/service/page_translation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/device_service.dart';
import 'package:town_pass/service/geo_locator_service.dart';
import 'package:town_pass/service/notification_service.dart';
import 'package:town_pass/service/package_service.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/service/subscription_service.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/page/assistant/assistant_view_controller.dart';
import 'package:town_pass/page/assistant/widget/assistant_host.dart';
import 'package:town_pass/page/guided_assistant/guided_assistant_controller.dart';
import 'package:town_pass/page/guided_assistant/model/guide_i18n.dart';
import 'package:town_pass/service/assistant_on_device.dart';
import 'package:town_pass/service/assistant_recorder.dart';
import 'package:town_pass/service/assistant_service.dart';
import 'package:town_pass/page/guided_assistant/web/web_page_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';

const assistantEnabled = bool.fromEnvironment(
  'ASSISTANT_ENABLED',
  defaultValue: kDebugMode,
);

/// The guided assistant is the default (owner, 2026-11-08): step-by-step guides
/// on the real service pages; it asks the model for service requests and falls
/// back to the pre-written rules when the backend cannot be reached.
/// `--dart-define=ASSISTANT_GUIDED=false` brings back the chat-only assistant
/// (docs/TEAM_TASKS_AFTER_MERGE.md T3-T5 list what it still lacks there).
/// `--dart-define=ASSISTANT_OFFLINE=true` makes the guided assistant never
/// call the backend.
const assistantGuided = bool.fromEnvironment(
  'ASSISTANT_GUIDED',
  defaultValue: true,
);
const assistantOffline = bool.fromEnvironment('ASSISTANT_OFFLINE');
const _useMock = assistantEnabled && assistantGuided;
const _useModel = assistantEnabled && !assistantGuided;

const _transparentStatusBar = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // FlutterNativeSplash.preserve(
  //   widgetsBinding: WidgetsFlutterBinding.ensureInitialized(),
  // );

  await initServices();

  SystemChrome.setSystemUIOverlayStyle(_transparentStatusBar);

  runApp(const MyApp());
}

Future<void> initServices() async {
  await Get.putAsync<AccountService>(() async => await AccountService().init());
  await Get.putAsync<DeviceService>(() async => await DeviceService().init());
  await Get.putAsync<PackageService>(() async => await PackageService().init());
  await Get.putAsync<SharedPreferencesService>(
    () async => await SharedPreferencesService().init(),
  );
  await Get.putAsync<GeoLocatorService>(
    () async => await GeoLocatorService().init(),
  );
  await Get.putAsync<NotificationService>(
    () async => await NotificationService().init(),
  );

  Get.put<SubscriptionService>(SubscriptionService());
  // Pages keep the language of the last assistant navigation (or Settings).
  await PageTranslation.instance.load();
  // The guided assistant's pre-translated texts (assets/i18n/guide/).
  if (_useMock) await GuideI18n.load();
  // iOS builds with ASSISTANT_ON_DEVICE=true run the backend and models on the
  // phone (docs/AI_ON_DEVICE_IOS.md); not awaited: the models load behind it.
  if (assistantEnabled && !assistantOffline) {
    unawaited(AssistantOnDevice.start());
  }
  if (_useMock) {
    Get.put<WebPageState>(WebPageState(), permanent: true);
    Get.put<GuidedAssistantController>(
      assistantOffline
          ? GuidedAssistantController()
          : GuidedAssistantController(
              service: AssistantService(),
              recorder: AssistantRecorder(),
            ),
      permanent: true,
    );
  }
  if (_useModel) {
    Get.put<AssistantViewController>(
      AssistantViewController(),
      permanent: true,
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Town Pass',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: TPColors.grayscale50,
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: TPColors.white,
        ),
        colorScheme: ColorScheme.fromSeed(seedColor: TPColors.primary500),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0.0,
          iconTheme: IconThemeData(size: 56),
          actionsIconTheme: IconThemeData(size: 56),
        ),
        actionIconTheme: ActionIconThemeData(
          backButtonIconBuilder: (_) => Semantics(
            excludeSemantics: true,
            child: Assets.svg.iconArrowLeft.svg(width: 24, height: 24),
          ),
        ),
      ),
      debugShowCheckedModeBanner: false,
      initialRoute: TPRoute.main,
      onInit: () {
        NotificationService.requestPermission();
      },
      getPages: TPRoute.page,
      navigatorObservers: [
        if (_useModel)
          AssistantNavigationObserver(Get.find<AssistantViewController>()),
        if (_useMock)
          GuidedNavigationObserver(Get.find<GuidedAssistantController>()),
      ],
      routingCallback: (routing) {
        if (_useModel && Get.isRegistered<AssistantViewController>()) {
          Get.find<AssistantViewController>().routeChanged(
            routing?.current ?? '',
          );
        }
        if (_useMock && Get.isRegistered<GuidedAssistantController>()) {
          Get.find<GuidedAssistantController>().routeChanged(
            routing?.current ?? '',
          );
        }
      },
      builder: (context, child) {
        final page = child ?? const SizedBox.shrink();
        if (_useMock) {
          return GuidedAssistantHost(
            controller: Get.find<GuidedAssistantController>(),
            child: page,
          );
        }
        if (_useModel) {
          return AssistantHost(
            controller: Get.find<AssistantViewController>(),
            child: page,
          );
        }
        return page;
      },
    );
  }
}
