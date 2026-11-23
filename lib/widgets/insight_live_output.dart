import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/utils/typewriter_text.dart';

class InsightLiveOutputController extends ChangeNotifier {
  static const _interval = Duration(milliseconds: 44);

  final reasoning = TypewriterText();
  final content = TypewriterText();
  String status = '';
  Timer? _timer;
  int _idleTicks = 0;

  void append(String delta, {required bool reasoning}) {
    if (delta.isEmpty) {
      return;
    }
    (reasoning ? this.reasoning : content).append(delta);
    _idleTicks = 0;
    _timer ??= Timer.periodic(_interval, _tick);
  }

  void updateStatus(String message) {
    status = message;
    notifyListeners();
  }

  void _tick(Timer _) {
    final allowTail = ++_idleTicks >= 3;
    final reasoningChanged = reasoning.advance(allowTail: allowTail);
    final contentChanged = content.advance(allowTail: allowTail);
    if (reasoningChanged || contentChanged) {
      notifyListeners();
    }
    if ((!reasoning.hasPending && !content.hasPending) ||
        (allowTail && !reasoningChanged && !contentChanged)) {
      stop();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class InsightLiveOutput extends StatefulWidget {
  const InsightLiveOutput({required this.controller, super.key});

  final InsightLiveOutputController controller;

  @override
  State<InsightLiveOutput> createState() => _InsightLiveOutputState();
}

class _InsightLiveOutputState extends State<InsightLiveOutput> {
  final _scroll = ScrollController();
  bool _following = true;
  bool _dragging = false;
  bool _scrollScheduled = false;
  bool _autoScrolling = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _dragging = true;
    }
    if (notification is UserScrollNotification &&
        notification.direction == ScrollDirection.forward) {
      _setFollowing(false);
    }
    if (notification is ScrollEndNotification) {
      _dragging = false;
      if (notification.metrics.extentAfter <= 12) {
        _setFollowing(true);
      }
    }
    return false;
  }

  void _setFollowing(bool value) {
    if (_following != value) {
      setState(() => _following = value);
    }
    if (value) {
      _followOutput();
    }
  }

  void _followOutput() {
    if (!_following || _dragging || _scrollScheduled || _autoScrolling) {
      return;
    }
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scrollScheduled = false;
      if (!mounted || !_following || _dragging || !_scroll.hasClients) {
        return;
      }
      final position = _scroll.position;
      if (position.extentAfter < 1) {
        return;
      }
      final end = position.maxScrollExtent;
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(end);
        return;
      }
      _autoScrolling = true;
      try {
        await _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
        );
      } finally {
        _autoScrolling = false;
        if (mounted &&
            !_dragging &&
            _following &&
            _scroll.hasClients &&
            _scroll.position.extentAfter >= 1) {
          _followOutput();
          WidgetsBinding.instance.ensureVisualUpdate();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizationsSimple.of(context) ??
        AppLocalizationsSimple(Localizations.localeOf(context));

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final reasoning = controller.reasoning;
        final body = controller.content;
        final reasoningCount = reasoning.hasText ? reasoning.blockCount + 1 : 0;
        final bodyCount = body.hasText ? body.blockCount + 1 : 0;
        final paused = !_following && reasoningCount + bodyCount > 0;
        _followOutput();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      controller.status.isNotEmpty
                          ? controller.status
                          : body.hasText
                              ? l10n.aiInsightWriting
                              : reasoning.hasText
                                  ? l10n.aiInsightThinking
                                  : l10n.aiInsightGenerating,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (paused)
                    TextButton.icon(
                      onPressed: () => _setFollowing(true),
                      icon: const Icon(Icons.arrow_downward_rounded, size: 16),
                      label: Text(l10n.aiInsightLatest),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: 0.035),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: reasoningCount + bodyCount == 0
                      ? _placeholder(colors)
                      : NotificationListener<ScrollNotification>(
                          onNotification: _handleScroll,
                          child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(16),
                            itemCount: reasoningCount + bodyCount,
                            itemBuilder: (context, index) {
                              final isReasoning = index < reasoningCount;
                              final textIndex =
                                  isReasoning ? index : index - reasoningCount;
                              if (textIndex == 0) {
                                return Padding(
                                  padding: EdgeInsets.only(
                                    top: isReasoning || reasoningCount == 0
                                        ? 0
                                        : 18,
                                    bottom: 8,
                                  ),
                                  child: Text(
                                    isReasoning
                                        ? l10n.aiInsightReasoningHeading
                                        : l10n.aiInsightReportHeading,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: isReasoning
                                          ? colors.onSurfaceVariant
                                          : colors.primary,
                                    ),
                                  ),
                                );
                              }
                              final text = isReasoning ? reasoning : body;
                              final caret = textIndex == text.blockCount &&
                                  (!isReasoning || !body.hasText);
                              return _textBlock(
                                text.blockAt(textIndex - 1),
                                theme,
                                isReasoning: isReasoning,
                                caret: caret,
                              );
                            },
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _textBlock(
    String text,
    ThemeData theme, {
    required bool isReasoning,
    required bool caret,
  }) {
    if (text.isEmpty && !caret) {
      return const SizedBox.shrink();
    }
    final newlineLength =
        text.endsWith('\r\n') ? 2 : (text.endsWith('\n') ? 1 : 0);
    final line = newlineLength == 0
        ? text
        : text.substring(0, text.length - newlineLength);
    final colors = theme.colorScheme;
    final style =
        (isReasoning ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
            ?.copyWith(
      height: 1.65,
      color: isReasoning ? colors.onSurfaceVariant : colors.onSurface,
    );
    if (!caret) {
      return Text(line.isEmpty ? ' ' : line, style: style);
    }
    return Text.rich(
      TextSpan(
        text: line,
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: ExcludeSemantics(
              child: Container(
                key: const ValueKey('insight-live-caret'),
                margin: const EdgeInsetsDirectional.only(start: 2),
                width: 2,
                height: 13,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ),
          ),
        ],
      ),
      style: style,
    );
  }

  Widget _placeholder(ColorScheme colors) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            for (final width in const [1.0, 0.84, 0.62])
              FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: width,
                child: Container(
                  height: 9,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: colors.onSurface.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
          ],
        ),
      );
}
