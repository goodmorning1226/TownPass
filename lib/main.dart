import 'package:flutter/material.dart';
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
import 'package:town_pass/util/town_pass_assistant_host.dart';
import 'package:townpass_portal_assistant/townpass_portal_assistant.dart';

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
  await Get.putAsync<SharedPreferencesService>(() async => await SharedPreferencesService().init());
  await Get.putAsync<GeoLocatorService>(() async => await GeoLocatorService().init());
  await Get.putAsync<NotificationService>(() async => await NotificationService().init());

  Get.put<SubscriptionService>(SubscriptionService());
  // Portal assistant (portal_assistant/INTEGRATION.md): page language, models, guides.
  await PortalAssistant.init(const TownPassAssistantHost());
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
      // Portal assistant: follows the routes and draws above every page.
      navigatorObservers: PortalAssistant.navigatorObservers,
      routingCallback: PortalAssistant.routingCallback,
      builder: PortalAssistant.builder,
    );
  }
}