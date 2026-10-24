import 'dart:convert';

import 'api_client.dart';

// This envelope is consumed by Codex TUI's async_question_reply parser. IDs
// include the original question index, even when earlier questions are answered.
String asyncQuestionId(String messageId, String index) =>
    jsonEncode(['request_user_input_async', messageId, int.parse(index)]);

class QuestionReply {
  const QuestionReply(this.id, this.question, this.answer);
  final String id, question, answer;
  static const _open = '<send_user_message_question_reply>';
  static const _close = '</send_user_message_question_reply>';

  static String encode(Iterable<QuestionReply> replies) =>
      '$_open${jsonEncode([
        for (final reply in replies) {'questionItemId': reply.id, 'question': reply.question, 'answer': reply.answer},
      ])}$_close';

  static List<QuestionReply> parse(String text) {
    var value = text.trim();
    if (value.startsWith('# Context from my IDE setup:\n')) {
      value = value.split('\n## My request for Codex:\n').last.trim();
    }
    if (!value.startsWith(_open) || !value.endsWith(_close)) return [];
    try {
      final decoded = jsonDecode(
        value.substring(_open.length, value.length - _close.length),
      );
      final entries = decoded is List ? decoded : [decoded];
      final replies = <QuestionReply>[];
      for (final entry in entries) {
        if (entry is! Map ||
            entry['questionItemId'] is! String ||
            entry['question'] is! String ||
            entry['answer'] is! String) {
          return [];
        }
        replies.add(
          QuestionReply(
            entry['questionItemId'],
            entry['question'],
            entry['answer'],
          ),
        );
      }
      return replies;
    } on FormatException {
      return [];
    }
  }

  static List<QuestionReply> fromContent(dynamic content) {
    final input = asMaps(content)
        .where((p) => p['type'] != 'skill' && p['type'] != 'mention')
        .toList();
    if (input.length != 1 || input.single['type'] != 'text') return [];
    return parse(input.single['text'] as String? ?? '');
  }

  String get displayText => '> $question\n\n$answer';
}

class CodexQuestion {
  const CodexQuestion({
    required this.id,
    required this.title,
    this.header = '',
    this.options = const [],
    this.allowOther = true,
    this.secret = false,
  });
  final String id, title, header;
  final List<({String label, String description})> options;
  final bool allowOther, secret;

  static List<CodexQuestion> parse(
    dynamic value, {
    bool asynchronous = false,
  }) => [
    for (final (index, q) in asMaps(value).indexed)
      CodexQuestion(
        id: asynchronous ? '$index' : q['id'] as String,
        title: (q[asynchronous ? 'title' : 'question'] as String?) ?? '',
        header: q['header'] as String? ?? '',
        allowOther:
            asynchronous ||
            q['isOther'] == true ||
            asMaps(q['options']).isEmpty,
        secret: q['isSecret'] == true,
        options: asynchronous
            ? [
                for (final label
                    in (q['options'] as List? ?? const []).whereType<String>())
                  (label: label, description: ''),
              ]
            : [
                for (final option in asMaps(q['options']))
                  (
                    label: option['label'] as String? ?? '',
                    description: option['description'] as String? ?? '',
                  ),
              ],
      ),
  ];
}

// Answers stay in memory, including secret input. They never enter draft storage.
class QuestionDraft {
  QuestionDraft({
    required this.threadId,
    required List<CodexQuestion> questions,
    required this.sourceId,
    this.approvalId,
  }) : questions = List.of(questions);
  final String threadId, sourceId;
  final String? approvalId;
  final List<CodexQuestion> questions;
  final Map<String, int> selections = {};
  final Map<String, String> text = {};
  bool busy = false, sent = false;
  String? requestId;

  String answer(CodexQuestion q) {
    final selected = selections[q.id];
    if (selected != null && selected >= 0) return q.options[selected].label;
    return q.options.isEmpty || selected == -1 ? (text[q.id] ?? '').trim() : '';
  }

  bool get valid =>
      questions.isNotEmpty && questions.every((q) => answer(q).isNotEmpty);
  JsonMap get result => {
    'answers': {
      for (final q in questions)
        q.id: {
          'answers': [answer(q)],
        },
    },
  };
  String get message => QuestionReply.encode([
    for (final q in questions)
      QuestionReply(asyncQuestionId(sourceId, q.id), q.title, answer(q)),
  ]);

  void resolve(Set<String> ids) {
    if (approvalId != null || ids.isEmpty) return;
    questions.removeWhere((q) {
      if (!ids.contains(sourceId) &&
          !ids.contains(asyncQuestionId(sourceId, q.id))) {
        return false;
      }
      text.remove(q.id);
      selections.remove(q.id);
      return true;
    });
    if (questions.isEmpty) {
      sent = true;
      requestId = null;
    }
  }
}
