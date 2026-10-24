import 'package:flutter/material.dart';

import '../data/conversation_controller.dart';
import '../data/questions.dart';

class QuestionBar extends StatelessWidget {
  const QuestionBar({super.key, required this.controller});
  final ConversationController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final pending = controller.pendingQuestions;
      if (pending.isEmpty) return const SizedBox.shrink();
      final response = pending.first;
      final count = pending.fold<int>(
        0,
        (sum, draft) => sum + draft.questions.length,
      );
      final colors = Theme.of(context).colorScheme;
      return Container(
        key: const ValueKey('question-bar'),
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.question_answer_outlined,
              size: 17,
              color: colors.primary,
            ),
            const SizedBox(width: 8),
            Text('$count 个问题', style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                response.questions.first.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: !controller.questionAvailable(response)
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (_) => QuestionDialog(
                        controller: controller,
                        response: response,
                      ),
                    ),
              child: Text(response.requestId != null ? '核对提交结果' : '回答问题'),
            ),
          ],
        ),
      );
    },
  );
}

class QuestionDialog extends StatefulWidget {
  const QuestionDialog({
    super.key,
    required this.controller,
    required this.response,
  });
  final ConversationController controller;
  final QuestionDraft response;
  @override
  State<QuestionDialog> createState() => _QuestionDialogState();
}

class _QuestionDialogState extends State<QuestionDialog> {
  late final _text = {
    for (final q in widget.response.questions)
      q.id: TextEditingController(text: widget.response.text[q.id]),
  };
  String? _error;

  Future<void> _submit() async {
    setState(() => _error = null);
    try {
      await widget.controller.submitQuestion(widget.response);
      if (mounted && widget.response.sent) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final response = widget.response;
      final available = widget.controller.questionAvailable(response);
      final editable =
          available && !response.busy && response.requestId == null;
      return PopScope(
        canPop: !response.busy,
        child: AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: const Text('回答 Codex'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              // Tile ink must scroll inside this viewport, not paint on the
              // dialog's Material behind its fixed title and actions.
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!available)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('问题已处理或失效，请返回会话查看最新状态。'),
                      ),
                    for (final (index, q) in response.questions.indexed) ...[
                      if (q.header.isNotEmpty)
                        Text(
                          q.header,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 12,
                          ),
                        ),
                      Text(
                        '${response.questions.length > 1 ? '${index + 1}. ' : ''}${q.title}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      for (final (optionIndex, option) in q.options.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            key: ValueKey(
                              'question-${q.id}-option-$optionIndex',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: response.selections[q.id] == optionIndex
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                              ),
                            ),
                            leading: Icon(
                              response.selections[q.id] == optionIndex
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(option.label),
                            subtitle: option.description.isEmpty
                                ? null
                                : Text(option.description),
                            selected: response.selections[q.id] == optionIndex,
                            enabled: editable,
                            onTap: editable
                                ? () => setState(() {
                                    response.selections[q.id] = optionIndex;
                                  })
                                : null,
                          ),
                        ),
                      if (q.allowOther && q.options.isNotEmpty)
                        ListTile(
                          key: ValueKey('question-${q.id}-other'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          leading: Icon(
                            response.selections[q.id] == -1
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                          ),
                          title: const Text('其他回答'),
                          selected: response.selections[q.id] == -1,
                          enabled: editable,
                          onTap: editable
                              ? () => setState(() {
                                  response.selections[q.id] = -1;
                                })
                              : null,
                        ),
                      if (q.options.isEmpty || response.selections[q.id] == -1)
                        TextField(
                          key: ValueKey('question-${q.id}-text'),
                          controller: _text[q.id],
                          enabled: editable,
                          obscureText: q.secret,
                          enableSuggestions: !q.secret,
                          autocorrect: !q.secret,
                          maxLines: q.secret ? 1 : 4,
                          minLines: 1,
                          maxLength: 20000,
                          decoration: const InputDecoration(
                            labelText: '你的回答',
                            counterText: '',
                          ),
                          onChanged: (text) =>
                              setState(() => response.text[q.id] = text),
                        ),
                      const SizedBox(height: 20),
                    ],
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (response.requestId != null && !response.busy)
                      TextButton(
                        onPressed: () => setState(() {
                          response.requestId = null;
                          _error = null;
                        }),
                        child: const Text('已核对记录，确认未发送，重新回答'),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: response.busy ? null : () => Navigator.pop(context),
              child: Text(available ? '稍后回答' : '关闭'),
            ),
            FilledButton(
              onPressed:
                  !available ||
                      response.busy ||
                      (!response.valid && response.requestId == null)
                  ? null
                  : _submit,
              child: Text(
                response.busy
                    ? '正在提交…'
                    : response.requestId != null
                    ? '核对提交结果'
                    : '提交回答',
              ),
            ),
          ],
        ),
      );
    },
  );

  @override
  void dispose() {
    for (final text in _text.values) {
      text.dispose();
    }
    super.dispose();
  }
}
