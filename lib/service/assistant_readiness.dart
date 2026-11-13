import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:town_pass/service/assistant_service.dart';

/// Whether the phone's models have loaded yet (docs/AI_CURRENT_RULES.md
/// section 5). Right after launch they are still loading for up to a minute;
/// a request sent then waits in the backend instead of failing, and the
/// waiting line says the models are loading ([loading]).
///
/// [watch] asks GET /health until `ready` says both the decision model and
/// speech answer (null for either: not on this phone). Only in on-device
/// builds (main.dart); elsewhere [loading] stays false. In classifier builds
/// (ASSISTANT_DECISION_MODEL=classifier) the backend reports the decision
/// classifier as `decision`: there is no decision LLM to wait for.
class AssistantReadiness {
  static final ValueNotifier<bool> loading = ValueNotifier(false);
  static Timer? _timer;

  /// Whether a /health reply says the models answer.
  static bool readyIn(Map<String, dynamic> health) {
    final ready = health['ready'];
    if (ready is! Map) return true; // an older backend: nothing to wait for
    return ready['decision'] != false && ready['speech'] != false;
  }

  static void watch(
    AssistantService service, {
    Duration every = const Duration(seconds: 2),
    Duration limit = const Duration(minutes: 5),
  }) {
    _timer?.cancel();
    loading.value = true;
    final watch = Stopwatch()..start();
    var asking = false;
    Future<void> ask() async {
      if (asking) return;
      asking = true;
      try {
        if (readyIn(await service.health())) stop();
      } on FormatException {
        // The backend itself is still starting.
      } finally {
        asking = false;
      }
      if (watch.elapsed >= limit) stop();
    }

    _timer = Timer.periodic(every, (_) => ask());
    unawaited(ask());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    loading.value = false;
  }
}
