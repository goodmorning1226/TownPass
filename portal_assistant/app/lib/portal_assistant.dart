import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:townpass_portal_assistant/host/portal_assistant_host.dart';
import 'package:townpass_portal_assistant/page/assistant/assistant_view_controller.dart';
import 'package:townpass_portal_assistant/page/assistant/widget/assistant_host.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/assistant_settings_view.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/guided_assistant_controller.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/assistant_settings.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/model/guide_i18n.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/web/web_page_state.dart';
import 'package:townpass_portal_assistant/page/guided_assistant/widget/guided_assistant_host.dart';
import 'package:townpass_portal_assistant/service/assistant_catalog_data.dart';
import 'package:townpass_portal_assistant/service/assistant_model_download.dart';
import 'package:townpass_portal_assistant/service/assistant_on_device.dart';
import 'package:townpass_portal_assistant/service/assistant_readiness.dart';
import 'package:townpass_portal_assistant/service/assistant_recorder.dart';
import 'package:townpass_portal_assistant/service/assistant_service.dart';
import 'package:townpass_portal_assistant/service/page_translation.dart';
import 'package:townpass_portal_assistant/util/assistant_data_licenses.dart';

/// Whether the App runs the assistant (`--dart-define=ASSISTANT_ENABLED`,
/// on in debug builds). Without it the App only keeps the page language
/// (PageTranslation) and the page tracking its WebViews do.
const assistantEnabled = bool.fromEnvironment(
  'ASSISTANT_ENABLED',
  defaultValue: kDebugMode,
);

/// The guided assistant is the default (owner, 2026-11-08): step-by-step guides
/// on the real service pages; it asks the model for service requests and falls
/// back to the pre-written rules when the backend cannot be reached.
/// `--dart-define=ASSISTANT_GUIDED=false` brings back the chat-only assistant
/// (portal_assistant/docs/history/TEAM_TASKS_AFTER_MERGE.md T3-T5 list what it still
/// lacks there). `--dart-define=ASSISTANT_OFFLINE=true` makes the guided
/// assistant never call the backend.
const assistantGuided = bool.fromEnvironment(
  'ASSISTANT_GUIDED',
  defaultValue: true,
);
const assistantOffline = bool.fromEnvironment('ASSISTANT_OFFLINE');
const _useMock = assistantEnabled && assistantGuided;
const _useModel = assistantEnabled && !assistantGuided;

/// The assistant's entry points for the host App (TownPass main.dart and
/// tp_route.dart); portal_assistant/INTEGRATION.md shows where each goes.
abstract final class PortalAssistant {
  /// Registers [host] and starts the assistant; the host App awaits it at
  /// the end of its service initialisation (after its own services).
  static Future<void> init(PortalAssistantHost host) async {
    PortalAssistantHost.instance = host;
    // The service origins and the catalogue's suggestions (data files read
    // synchronously later: page tracking, translation, opening pages).
    await AssistantCatalogData.load();
    // Pages keep the language of the last assistant navigation (or Settings).
    await PageTranslation.instance.load();
    // The guided assistant's pre-translated texts (portal_assistant/app/assets/i18n/guide/).
    if (_useMock) await GuideI18n.load();
    // iOS builds with ASSISTANT_ON_DEVICE=true run the backend and models on
    // the phone (portal_assistant/docs/AI_ON_DEVICE_IOS.md); not awaited:
    // the models load behind it.
    if (assistantEnabled && !assistantOffline) {
      unawaited(AssistantOnDevice.start());
      // On-device builds (Android and iPhone) download their models in the
      // App when the user agrees (portal_assistant/docs/AI_MODEL_DOWNLOAD.md).
      if (AssistantOnDevice.requested) {
        Get.put<AssistantModelDownload>(
          AssistantModelDownload(),
          permanent: true,
        );
        // The models load for up to a minute after launch: the waiting line
        // says so until they answer (AssistantReadiness).
        AssistantReadiness.watch(AssistantService());
      }
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
    // The data and model sources on the licence page (設定 → 授權與資料來源).
    if (assistantEnabled) AssistantDataLicenses.register();
  }

  /// The assistant's pages, added to the host's GetPage list (TPRoute.page).
  static List<GetPage> get pages => [
    GetPage(
      name: assistantSettingsRoute,
      page: () => const AssistantSettingsView(),
    ),
  ];

  /// GetMaterialApp.navigatorObservers.
  static List<NavigatorObserver> get navigatorObservers => [
    if (_useModel)
      AssistantNavigationObserver(Get.find<AssistantViewController>()),
    if (_useMock)
      GuidedNavigationObserver(Get.find<GuidedAssistantController>()),
  ];

  /// GetMaterialApp.routingCallback.
  static void routingCallback(Routing? routing) {
    if (_useModel && Get.isRegistered<AssistantViewController>()) {
      Get.find<AssistantViewController>().routeChanged(routing?.current ?? '');
    }
    if (_useMock && Get.isRegistered<GuidedAssistantController>()) {
      Get.find<GuidedAssistantController>().routeChanged(
        routing?.current ?? '',
      );
    }
  }

  /// GetMaterialApp.builder: the assistant's overlay above every page.
  static Widget builder(BuildContext context, Widget? child) {
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
  }

  /// Whether the guided assistant runs (the host shows AI 助理設定 then).
  static bool get guidedAvailable =>
      Get.isRegistered<GuidedAssistantController>();

  /// The guided assistant; only while [guidedAvailable].
  static GuidedAssistantController get guided =>
      Get.find<GuidedAssistantController>();
}
