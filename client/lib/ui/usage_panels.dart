import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/app_controller.dart';
import '../data/conversation_controller.dart';
import '../data/models.dart';

Future<void> showAccountPanel(
  BuildContext context,
  AppController controller,
) async {
  controller.refreshUsage();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (context) => SafeArea(
      child: FractionallySizedBox(
        heightFactor: .82,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => AccountPanel(controller: controller),
        ),
      ),
    ),
  );
}

class AccountPanel extends StatelessWidget {
  const AccountPanel({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final value = controller.accountUsage;
    final account = asMap(asMap(value['account'])['account']);
    final tokens = asMap(value['tokens']);
    final summary = asMap(tokens['summary']);
    final today = asMaps(tokens['dailyUsageBuckets'])
        .where((b) => b['startDate'] == value['today'])
        .firstOrNull;
    final limits = asMap(value['rateLimits']);
    final byId = asMap(limits['rateLimitsByLimitId']);
    final buckets = byId.isNotEmpty
        ? byId.entries.map((e) => (e.key, asMap(e.value))).toList()
        : <(String, JsonMap)>[('codex', asMap(limits['rateLimits']))];
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '账号用量',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '刷新用量',
              onPressed: () => controller.refreshUsage(force: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        Text(
          account['email'] as String? ?? '本机当前 Codex 账号',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: _stat(context, '今日 Token', today?['tokens'] as num?),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stat(
                context,
                '累计 Token',
                summary['lifetimeTokens'] as num?,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '统计日期 ${value['today'] ?? '待更新'} · ${value['timeZone'] ?? ''}\n官方日统计可能延迟；官方日界线时区未公开。',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
        if (value['tokensError'] != null || value['error'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Token 统计暂不可用：${value['tokensError'] ?? value['error']}',
              style: TextStyle(fontSize: 12, color: colors.error),
            ),
          ),
        const SizedBox(height: 26),
        const Text(
          '使用额度',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (value['limitsError'] != null)
          Text(
            '额度更新失败，已有数值为上次读取结果。',
            style: TextStyle(fontSize: 12, color: colors.error),
          ),
        for (final (id, bucket) in buckets) ...[
          if (buckets.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                bucket['limitName'] as String? ?? id,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          for (final key in ['primary', 'secondary'])
            if ([300, 10080].contains(asMap(bucket[key])['windowDurationMins']))
              QuotaRow(window: asMap(bucket[key])),
        ],
        if (!buckets.any(
          (b) => ['primary', 'secondary'].any(
            (k) => [300, 10080].contains(asMap(b.$2[k])['windowDurationMins']),
          ),
        ))
          Text(
            value['limitsError'] == null ? '当前账号未提供可显示的额度窗口。' : '额度暂时无法读取。',
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
        const SizedBox(height: 16),
        Text(
          'Token 更新：${_date(value['tokensUpdatedAt'])}\n额度更新：${_date(value['limitsUpdatedAt'])}',
          style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Text(
          '累计值来自 Codex 官方账号统计，包含其他客户端的使用；不等同于当前会话消耗。',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, num? count) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 7),
        Text(
          compactNumber(count),
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        Text(count?.toString() ?? '待更新', style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
  String _date(dynamic value) {
    final date = value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return date == null
        ? '待更新'
        : '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class QuotaRow extends StatelessWidget {
  const QuotaRow({super.key, required this.window});
  final JsonMap window;
  @override
  Widget build(BuildContext context) {
    final used = window['usedPercent'] as num?;
    final reset = window['resetsAt'] as num?;
    final date = reset == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(reset.toInt() * 1000).toLocal();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                window['windowDurationMins'] == 300
                    ? '5 小时额度'
                    : 'Weekly · 每周额度',
              ),
              const Spacer(),
              Text(
                used == null ? '待更新' : '已用 $used%',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 9),
          LinearProgressIndicator(
            value: used == null ? null : (used / 100).clamp(0, 1).toDouble(),
            minHeight: 7,
            borderRadius: BorderRadius.circular(8),
          ),
          if (date != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '重置于 ${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}（设备时间）',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> showSessionUsage(
  BuildContext context,
  ConversationController controller,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (context) => SafeArea(
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final usage = controller.usage;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '会话与上下文',
                style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 20),
              _metric('会话累计 Token', usage.total),
              _metric('输入', usage.input),
              _metric('其中缓存输入', usage.cached),
              _metric('输出', usage.output),
              _metric('其中推理输出', usage.reasoning),
              const Divider(height: 28),
              _metric('上下文窗口', usage.window),
              _metric('最近报告的上下文占用', usage.last),
              const SizedBox(height: 10),
              Text(
                usage.fraction == null
                    ? '上下文占用待更新'
                    : '上下文约 ${(usage.fraction! * 100).toStringAsFixed(1)}%',
              ),
              const SizedBox(height: 8),
              if (usage.fraction != null)
                LinearProgressIndicator(
                  value: usage.fraction,
                  borderRadius: BorderRadius.circular(8),
                  minHeight: 7,
                ),
              const SizedBox(height: 18),
              const Text(
                '百分比按最近一次 Codex 报告估算，含输入与输出。压缩后可能下降。缓存与推理是明细，不重复计入总数。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        );
      },
    ),
  ),
);

Widget _metric(String label, num? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5),
  child: Row(
    children: [
      Expanded(child: Text(label)),
      Text(
        value?.toString() ?? '待更新',
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
    ],
  ),
);
