/// What the host App (TownPass) uses of the portal assistant: the host
/// interface it implements, the entry points main.dart and tp_route.dart
/// call, and the hooks its pages call (portal_assistant/INTEGRATION.md).
library;

export 'host/assistant_web_view.dart'
    show AssistantWebRequest, AssistantWebSession;
export 'host/portal_assistant_host.dart' show PortalAssistantHost;
export 'page/guided_assistant/assistant_settings_view.dart' show SettingsTag;
export 'page/guided_assistant/model/assistant_settings.dart'
    show SettingsTexts, assistantSettingsRoute;
export 'portal_assistant.dart';
export 'service/assistant_page_tracker.dart'
    show AssistantPageTracker, AssistantTabWebPage, AssistantWebPage;
export 'service/page_translation.dart'
    show PageTranslation, PageTranslationScope;
