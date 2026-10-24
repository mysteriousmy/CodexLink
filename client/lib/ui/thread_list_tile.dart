import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A thread's identity stays visible while its trailing actions are revealed.
class ThreadListTile extends StatefulWidget {
  const ThreadListTile({
    super.key,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.running,
    required this.selected,
    required this.revealed,
    required this.onReveal,
    required this.onOpen,
    required this.onArchive,
    required this.onClose,
    this.archived = false,
    this.busy = false,
    this.closing = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final bool running;
  final bool selected;
  final bool revealed;
  final bool archived;
  final bool busy;
  final bool closing;
  final ValueChanged<bool> onReveal;
  final VoidCallback onOpen;
  final VoidCallback? onArchive;
  final VoidCallback? onClose;

  @override
  State<ThreadListTile> createState() => _ThreadListTileState();
}

class _ThreadListTileState extends State<ThreadListTile>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  final _dialogRevision = ValueNotifier(0);
  bool _dialogOpen = false;
  bool _hovered = false;
  bool _focused = false;
  bool _dragging = false;
  double get _actionWidth => kIsWeb ? 44 : 64;
  double get _actionsWidth =>
      _actionWidth * (widget.running && !widget.closing ? 2 : 1);
  bool get _visible =>
      kIsWeb && (widget.revealed || _hovered || _focused || widget.busy);

  void _animate() =>
      _animation.animateTo(_visible ? 1 : 0, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    _animation.value = _visible ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant ThreadListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) _animate();
    if (_dialogOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _dialogRevision.value++;
      });
    }
  }

  Future<void> _showActions() async {
    if (widget.busy || _dialogOpen) return;
    _dialogOpen = true;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => ValueListenableBuilder(
        valueListenable: _dialogRevision,
        builder: (context, _, _) => AlertDialog(
          title: Text(
            widget.title,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  widget.archived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
                title: Text(widget.archived ? '恢复会话' : '归档会话'),
                enabled: !widget.busy && widget.onArchive != null,
                onTap: !widget.busy && widget.onArchive != null
                    ? () => Navigator.pop(
                        dialogContext,
                        widget.archived ? 'restore' : 'archive',
                      )
                    : null,
              ),
              if (widget.running && !widget.closing)
                ListTile(
                  leading: const Icon(Icons.close_rounded),
                  title: const Text('关闭会话'),
                  enabled: !widget.busy && widget.onClose != null,
                  onTap: !widget.busy && widget.onClose != null
                      ? () => Navigator.pop(dialogContext, 'close')
                      : null,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
    _dialogOpen = false;
    if (!mounted || widget.busy) return;
    if ((action == 'archive' && !widget.archived) ||
        (action == 'restore' && widget.archived)) {
      widget.onArchive?.call();
    } else if (action == 'close' && widget.running && !widget.closing) {
      widget.onClose?.call();
    }
  }

  Widget _action({
    required String tooltip,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    required Color color,
  }) => SizedBox(
    width: _actionWidth,
    child: Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        button: true,
        child: ExcludeSemantics(
          child: TextButton(
            onPressed: widget.busy ? null : onPressed,
            style: TextButton.styleFrom(
              foregroundColor: color,
              minimumSize: Size(_actionWidth, 64),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20),
                if (!kIsWeb) ...[
                  const SizedBox(height: 4),
                  Text(label, style: const TextStyle(fontSize: 11)),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final runningColor = theme.brightness == Brightness.dark
        ? const Color(0xff7cdcc0)
        : const Color(0xff147d64);
    return TapRegion(
      onTapOutside: (_) {
        if (widget.revealed) widget.onReveal(false);
      },
      child: MouseRegion(
        onEnter: (event) {
          if (event.kind != PointerDeviceKind.mouse &&
              event.kind != PointerDeviceKind.trackpad) {
            return;
          }
          _hovered = true;
          _animate();
        },
        onExit: (_) {
          _hovered = false;
          _animate();
        },
        child: Focus(
          skipTraversal: true,
          canRequestFocus: false,
          onFocusChange: (focused) {
            _focused = focused;
            _animate();
          },
          child: GestureDetector(
            supportedDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
            onHorizontalDragStart: !kIsWeb
                ? null
                : (_) {
                    _dragging = true;
                    _animation.stop();
                  },
            onHorizontalDragUpdate: !kIsWeb
                ? null
                : (event) {
                    _animation.value =
                        (_animation.value + event.delta.dx / _actionsWidth)
                            .clamp(0, 1);
                  },
            onHorizontalDragEnd: !kIsWeb
                ? null
                : (event) {
                    _dragging = false;
                    final velocity = event.primaryVelocity ?? 0;
                    widget.onReveal(
                      velocity.abs() > 250
                          ? velocity > 0
                          : _animation.value > .4,
                    );
                    _animate();
                  },
            onHorizontalDragCancel: !kIsWeb
                ? null
                : () {
                    _dragging = false;
                    _animate();
                  },
            child: Material(
              key: ValueKey('thread-surface-${widget.id}'),
              color: widget.running
                  ? runningColor.withValues(alpha: .10)
                  : widget.selected
                  ? colors.secondaryContainer.withValues(alpha: .7)
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: widget.selected
                    ? BorderSide(color: colors.primary.withValues(alpha: .55))
                    : BorderSide.none,
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedBuilder(
                animation: _animation,
                builder: (context, _) => Row(
                  children: [
                    Expanded(
                      child: ListTile(
                        key: ValueKey('thread-open-${widget.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        minLeadingWidth: 20,
                        horizontalTitleGap: 10,
                        leading: widget.busy
                            ? const SizedBox(
                                width: 19,
                                height: 19,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                widget.running
                                    ? Icons.motion_photos_on_rounded
                                    : Icons.chat_bubble_outline_rounded,
                                size: 19,
                                color: widget.running
                                    ? runningColor
                                    : colors.onSurfaceVariant,
                              ),
                        title: Text(
                          widget.title.replaceAll('\n', ' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: widget.running
                                ? runningColor
                                : colors.onSurface,
                            fontWeight: widget.running
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${widget.running ? '运行中 · ' : ''}${widget.closing ? '等待卸载 · ' : ''}${widget.subtitle}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onLongPress: kIsWeb || widget.busy
                            ? null
                            : _showActions,
                        onTap: widget.busy
                            ? null
                            : () {
                                widget.onReveal(false);
                                widget.onOpen();
                              },
                      ),
                    ),
                    if (kIsWeb)
                      ClipRect(
                        child: Align(
                          widthFactor: _animation.value,
                          alignment: Alignment.centerRight,
                          child: IgnorePointer(
                            ignoring: _animation.value < .99,
                            child: ExcludeFocus(
                              excluding: _animation.value == 0,
                              child: ExcludeSemantics(
                                excluding: _animation.value == 0,
                                child: SizedBox(
                                  width: _actionsWidth,
                                  child: Row(
                                    children: [
                                      _action(
                                        tooltip: widget.archived
                                            ? '恢复会话'
                                            : '归档会话',
                                        label: widget.archived ? '恢复' : '归档',
                                        icon: widget.archived
                                            ? Icons.unarchive_outlined
                                            : Icons.archive_outlined,
                                        onPressed: widget.onArchive,
                                        color: colors.primary,
                                      ),
                                      if (widget.running && !widget.closing)
                                        _action(
                                          tooltip: '关闭会话',
                                          label: '关闭',
                                          icon: Icons.close_rounded,
                                          onPressed: widget.onClose,
                                          color: colors.error,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _dialogRevision.dispose();
    _animation.dispose();
    super.dispose();
  }
}
