import 'package:town_pass/page/guided_assistant/model/guide_content.dart';

/// What the mock assistant decided to do with one sentence.
enum MockReplyKind {
  guide,
  openService,
  candidates,
  multi,
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

  /// For [MockReplyKind.multi]: the guide to offer after the first one.
  final String? otherGuideId;
  final CandidateGroup? candidates;
  final GlossaryEntry? term;
  final AnswerCardContent? answer;

  /// For [MockReplyKind.openService]: page title of a service without a guide.
  final String? serviceTitle;

  const MockReply(
    this.kind, {
    this.guideId,
    this.otherGuideId,
    this.candidates,
    this.term,
    this.answer,
    this.serviceTitle,
  });
}

/// Keyword rules standing in for the on-device model while the guided UI is
/// built. They only choose among the pre-written entries in guide_content.
class MockAssistantEngine {
  const MockAssistantEngine();

  static final _punct = RegExp(r'[\s，。、！？?!,.：:「」『』（）()]');
  static final _askMeaning = RegExp(r'什麼是|是什麼|什麼意思|看不懂|甚麼是|是甚麼');

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

    final water = t.contains('水費');
    final library = t.contains('底層邏輯') || (t.contains('借') && t.contains('書'));
    if (water && library) {
      return const MockReply(
        MockReplyKind.multi,
        guideId: GuideIds.library,
        otherGuideId: GuideIds.water,
      );
    }
    if (water) {
      return const MockReply(MockReplyKind.guide, guideId: GuideIds.water);
    }
    if (library) {
      return const MockReply(MockReplyKind.guide, guideId: GuideIds.library);
    }

    if (t.contains('停車')) {
      return const MockReply(MockReplyKind.openService, serviceTitle: '停車費');
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

  static GlossaryEntry? findTerm(String normalized) {
    for (final entry in glossary) {
      for (final alias in entry.aliases) {
        if (normalized.contains(alias.toLowerCase())) return entry;
      }
    }
    return null;
  }
}
