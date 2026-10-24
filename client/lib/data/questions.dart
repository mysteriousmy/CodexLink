import 'api_client.dart';

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
    required this.questions,
    this.approvalId,
  });
  final String threadId;
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
  String get message =>
      '回复 Codex 的问题：\n\n${questions.indexed.map((e) => '${e.$1 + 1}. ${e.$2.title}\n回答：${answer(e.$2)}').join('\n\n')}';
}
