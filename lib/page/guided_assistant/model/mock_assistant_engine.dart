import 'package:town_pass/page/guided_assistant/model/guide_content.dart';
import 'package:town_pass/page/guided_assistant/model/guides/guide_registry.dart';

/// What the mock assistant decided to do with one sentence.
enum MockReplyKind {
  guide,
  candidates,
  explain,
  answer,
  pageHelp,
  stepHelp,
  onboarding,
  greet,
  unknownTerm,
  unknown,
}

class MockReply {
  final MockReplyKind kind;
  final String? guideId;

  final CandidateGroup? candidates;
  final GlossaryEntry? term;
  final AnswerCardContent? answer;

  const MockReply(
    this.kind, {
    this.guideId,
    this.candidates,
    this.term,
    this.answer,
  });
}

/// Keyword rules standing in for the on-device model while the guided UI is
/// built. They only choose among the pre-written entries in guide_content.
class MockAssistantEngine {
  const MockAssistantEngine();

  static final _punct = RegExp(r'[\s，。、！？?!,.：:「」『』（）()]');
  static final _askMeaning = RegExp(r'什麼是|是什麼|什麼意思|看不懂|甚麼是|是甚麼|一樣嗎');

  static String normalize(String text) =>
      text.toLowerCase().replaceAll(_punct, '');

  MockReply interpret(String text, {bool hasTask = false}) {
    final t = normalize(text);
    if (t.isEmpty) return const MockReply(MockReplyKind.unknown);

    if (t.contains('教我用') || t.contains('怎麼用') || t.contains('使用教學')) {
      return const MockReply(MockReplyKind.onboarding);
    }

    if (_askMeaning.hasMatch(t)) {
      final term = findTerm(t);
      return term == null
          ? const MockReply(MockReplyKind.unknownTerm)
          : MockReply(MockReplyKind.explain, term: term);
    }

    if (t.contains('這頁') || t.contains('這一頁') || t.contains('這個頁面')) {
      return const MockReply(MockReplyKind.pageHelp);
    }

    if (t.contains('下一步') ||
        t.contains('我不會') ||
        t.contains('怎麼按') ||
        t.contains('現在要') ||
        t.contains('再說一次')) {
      return const MockReply(MockReplyKind.stepHelp);
    }

    final guideId = offlineGuideId(t);
    if (guideId != null) {
      return MockReply(MockReplyKind.guide, guideId: guideId);
    }

    if (t.contains('進度') || t.contains('案件') || t.contains('辦到哪')) {
      return const MockReply(
        MockReplyKind.candidates,
        candidates: caseProgress,
      );
    }

    if (t.contains('共餐') ||
        (t.contains('吃飯') && (t.contains('一起') || t.contains('老人')))) {
      return const MockReply(MockReplyKind.answer, answer: seniorMeals);
    }

    if (t.contains('你好') || t.contains('哈囉') || t == 'hi' || t == 'hello') {
      return const MockReply(MockReplyKind.greet);
    }

    return const MockReply(MockReplyKind.unknown);
  }

  /// The guide for a service request the pre-written fallback recognises
  /// (the model decides when it can be reached). Each page says which
  /// sentences are about it (GuidePage.offline).
  static String? offlineGuideId(String t) {
    for (final page in guidePages) {
      final cap = page.offline?.call(t);
      if (cap == null) continue;
      final destination = cap.isEmpty
          ? page.defaultDestination
          : <String, dynamic>{'kind': 'capability', 'id': cap};
      return guideForDestination(destination, null, t)?.id;
    }
    return null;
  }

  /// Library requests the pre-written fallback recognises.
  static bool isLibrary(String t) =>
      t.contains('圖書') ||
      t.contains('館藏') ||
      (t.contains('書') &&
          (t.contains('借') ||
              t.contains('預約') ||
              t.contains('找') ||
              t.contains('排行') ||
              t.contains('取'))) ||
      ((t.contains('圖書館') || t.contains('分館')) &&
          (t.contains('公告') || t.contains('地圖') || t.contains('在哪')));

  static GlossaryEntry? findTerm(String normalized) {
    for (final entry in glossary) {
      for (final alias in entry.aliases) {
        if (normalized.contains(alias.toLowerCase())) return entry;
      }
    }
    return null;
  }
}
