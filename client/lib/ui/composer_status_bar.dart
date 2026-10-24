import 'package:flutter/material.dart';

/// Compact, shared presentation for the composer’s goal, questions and queue.
class ComposerStatusBar extends StatelessWidget {
  const ComposerStatusBar({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actions,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: colors.primaryContainer.withValues(alpha: .4),
        borderRadius: radius,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: radius,
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: colors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              subtitle.replaceAll('\n', ' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}
