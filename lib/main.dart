import 'package:flutter/material.dart';
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
import 'package:town_pass/page/guided_assistant/model/mock_service_state.dart';
import 'package:town_pass/page/guided_assistant/widget/guided_assistant_host.dart';

const assistantEnabled = bool.fromEnvironment(
  'ASSISTANT_ENABLED',
  defaultValue: kDebugMode,
);

/// Guided assistant with pre-written content and keyword rules instead of the
/// model (UI prototype). `--dart-define=ASSISTANT_MOCK=false` brings back the
/// model-backed assistant.
const assistantMock = bool.fromEnvironment('ASSISTANT_MOCK', defaultValue: true);
const _useMock = assistantEnabled && assistantMock;
const _useModel = assistantEnabled && !assistantMock;

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
  if (_useMock) {
    Get.put<MockServiceState>(MockServiceState(), permanent: true);
    Get.put<GuidedAssistantController>(
      GuidedAssistantController(),
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
