import 'dart:math';

import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/widgets/memos_markdown_renderer.dart';
import 'package:provider/provider.dart';

typedef _WalkReason = ({String label, String evidence});

class RandomWalkCanvas extends StatefulWidget {
  const RandomWalkCanvas({
    required this.notes,
    required this.edges,
    required this.path,
    required this.current,
    required this.onSelect,
    this.action,
    this.status,
    super.key,
  });

  final List<WalkNote> notes;
  final List<WalkConnection> edges;
  final List<String> path;
  final Note current;
  String get focus => current.id;
  final ValueChanged<String> onSelect;
  final Widget? action;
  final Widget? status;

  static Color paperColor(ThemeData theme) =>
      theme.brightness == Brightness.dark
          ? const Color(0xFF191D1C)
          : const Color(0xFFF7F6F1);

  @override
  State<RandomWalkCanvas> createState() => _RandomWalkCanvasState();
}

class _RandomWalkCanvasState extends State<RandomWalkCanvas>
    with SingleTickerProviderStateMixin {
  static const _cardSize = Size(168, 130);
  static const _columnGap = 246.0;
  static const _rowGap = 146.0;
  static const _minScale = 0.42;
  static const _maxScale = 1.65;

  final _camera = TransformationController();
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..addListener(_moveCamera);
  Matrix4Tween? _flight;
  final _positions = <String, Offset>{};
  Size? _viewSize;
  Offset? _origin;
  String? _centeredFocus;
  bool _reading = false;
  double _graphScale = 1;
  double? _pendingScale;

  @override
  void initState() {
    super.initState();
    _updatePositions();
  }

  @override
  void didUpdateWidget(RandomWalkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus) {
      if (_reading) {
        _pendingScale = _graphScale;
      }
      _reading = false;
    }
    _updatePositions();
  }

  @override
  void dispose() {
    _motion.dispose();
    _camera.dispose();
    super.dispose();
  }

  void _updatePositions() {
    final path = widget.path;
    final next = widget.edges.where((edge) => edge.$1 == widget.focus).toList();
    _positions.removeWhere(
      (id, _) => !path.contains(id) && !next.any((edge) => edge.$2 == id),
    );
    for (var i = 0; i < path.length; i++) {
      final id = path[i];
      _positions[id] = Offset(i * _columnGap, _positions[id]?.dy ?? 0);
    }
    final focus = _positions[widget.focus]!;
    for (var i = 0; i < next.length; i++) {
      final dy = (i - (next.length - 1) / 2) * _rowGap;
      _positions[next[i].$2] = focus + Offset(_columnGap, dy);
    }
  }

  void _updateCamera(Size viewport, Offset origin, Offset focalPoint) {
    final previousOrigin = _origin;
    final firstFrame = _viewSize == null;
    final resized = _viewSize != viewport;
    final shouldCenter =
        firstFrame || resized || _centeredFocus != widget.focus;
    if (!shouldCenter && previousOrigin == origin) {
      return;
    }
    _viewSize = viewport;
    _origin = origin;
    _centeredFocus = widget.focus;
    final pendingScale = _pendingScale;
    _pendingScale = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _origin != origin) {
        return;
      }
      final currentScale = _camera.value.getMaxScaleOnAxis();
      final scale = firstFrame
          ? (viewport.width / 525).clamp(0.60, 0.91)
          : pendingScale ?? currentScale;
      if (previousOrigin != null && previousOrigin != origin) {
        _motion.stop();
        final translation = _camera.value.getTranslation();
        final delta = origin - previousOrigin;
        _camera.value = Matrix4.copy(_camera.value)
          ..setTranslationRaw(
            translation.x - delta.dx * currentScale,
            translation.y - delta.dy * currentScale,
            0,
          );
      }
      if (shouldCenter) {
        _aim(focalPoint, scale, animate: !resized);
      }
    });
  }

  void _moveCamera() {
    _camera.value =
        _flight!.transform(Curves.easeOutCubic.transform(_motion.value));
  }

  Offset get _anchor => Offset(
        _viewSize!.width * (_reading ? 0.5 : 0.34),
        _viewSize!.height * 0.46,
      );

  void _aim(Offset point, double scale, {bool animate = true}) {
    final offset = _anchor - point * scale;
    final target = Matrix4.diagonal3Values(scale, scale, scale)
      ..setTranslationRaw(offset.dx, offset.dy, 0);
    _motion.stop();
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
      _camera.value = target;
      return;
    }
    _flight = Matrix4Tween(begin: Matrix4.copy(_camera.value), end: target);
    _motion.forward(from: 0);
  }

  void _zoom(double factor) {
    final center = _camera.toScene(_anchor);
    final scale = (_camera.value.getMaxScaleOnAxis() * factor)
        .clamp(_minScale, _maxScale);
    _aim(center, scale);
  }

  void _toggleReading() {
    if (!_reading) {
      _graphScale = _camera.value.getMaxScaleOnAxis();
    }
    setState(() => _reading = !_reading);
    _aim(_positions[widget.focus]! + _origin!, _reading ? 0.94 : _graphScale);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.biggest;
          final left = _positions.values.map((p) => p.dx).reduce(min);
          final top = _positions.values.map((p) => p.dy).reduce(min);
          final right = _positions.values.map((p) => p.dx).reduce(max);
          final bottom = _positions.values.map((p) => p.dy).reduce(max);
          final origin = Offset(viewport.width - left, viewport.height - top);
          final size = Size(
            right - left + viewport.width * 2,
            bottom - top + viewport.height * 2,
          );
          final points =
              _positions.map((id, offset) => MapEntry(id, offset + origin));
          final theme = Theme.of(context);
          final l10n = AppLocalizationsSimple.of(context) ??
              AppLocalizationsSimple(Localizations.localeOf(context));
          final previous = widget.path.length > 1
              ? widget.path[widget.path.length - 2]
              : null;
          final outgoingReasons = <String, _WalkReason>{};
          _WalkReason? currentReason;
          for (final edge in widget.edges) {
            if (edge.$1 == widget.focus) {
              outgoingReasons[edge.$2] = _edgeReason(l10n, edge);
            } else if (edge.$1 == previous && edge.$2 == widget.focus) {
              currentReason = _edgeReason(l10n, edge);
            }
          }
          final hasEvidence = currentReason?.evidence.isNotEmpty ?? false;
          final focusSize = _reading
              ? Size(
                  min(288, viewport.width - 42),
                  (viewport.height * 0.72).clamp(150, 440),
                )
              : Size(216, hasEvidence ? 224 : 184);
          final cards = points.map((id, offset) {
            final size = id == widget.focus ? focusSize : _cardSize;
            return MapEntry(
              id,
              Rect.fromCenter(
                center: offset,
                width: size.width,
                height: size.height,
              ),
            );
          });
          _updateCamera(viewport, origin, points[widget.focus]!);
          final walked = <(String, String)>{
            for (var i = 1; i < widget.path.length; i++)
              (widget.path[i - 1], widget.path[i]),
          };
          return Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _PaperPainter(
                  RandomWalkCanvas.paperColor(theme),
                  theme.colorScheme.onSurface.withValues(alpha: 0.12),
                ),
              ),
              InteractiveViewer.builder(
                minScale: _minScale,
                maxScale: _maxScale,
                panEnabled: !_reading,
                onInteractionStart: (_) => _motion.stop(),
                transformationController: _camera,
                builder: (context, scene) {
                  final visible = Rect.fromPoints(
                    Offset(scene.point0.x, scene.point0.y),
                    Offset(scene.point2.x, scene.point2.y),
                  ).inflate(_cardSize.width);
                  return SizedBox.fromSize(
                    size: size,
                    child: CustomPaint(
                      painter: _WalkEdgesPainter(
                        cards: cards,
                        edges: widget.edges,
                        walked: walked,
                        lineColor:
                            theme.colorScheme.onSurface.withValues(alpha: 0.24),
                        pathColor: theme.colorScheme.primary,
                      ),
                      child: Stack(
                        children: [
                          for (final note in widget.notes)
                            if (note.id == widget.focus ||
                                visible.overlaps(cards[note.id]!))
                              Positioned.fromRect(
                                key: ValueKey(note.id),
                                rect: cards[note.id]!,
                                child: _WalkCard(
                                  note: note,
                                  selected: note.id == widget.focus,
                                  visited: widget.path.contains(note.id),
                                  reason: note.id == widget.focus
                                      ? currentReason
                                      : outgoingReasons[note.id],
                                  onTap: outgoingReasons.containsKey(note.id) ||
                                          note.id == previous
                                      ? () => widget.onSelect(note.id)
                                      : null,
                                  onRead: note.id == widget.focus
                                      ? _toggleReading
                                      : null,
                                  fullNote: note.id == widget.focus && _reading
                                      ? widget.current
                                      : null,
                                ),
                              ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (widget.action != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _WalkDock(
                    action: widget.action!,
                    status: widget.status,
                    onCenter: () => _aim(
                      points[widget.focus]!,
                      _camera.value.getMaxScaleOnAxis(),
                    ),
                    onZoomOut: () => _zoom(0.8),
                    onZoomIn: () => _zoom(1.25),
                  ),
                ),
            ],
          );
        },
      );
}

_WalkReason _edgeReason(AppLocalizationsSimple l10n, WalkConnection edge) {
  final label = switch (edge.$3) {
    WalkRelation.reference => l10n.randomWalkReference,
    WalkRelation.backlink => l10n.randomWalkBacklink,
    WalkRelation.tag => l10n.randomWalkTag,
    WalkRelation.text => l10n.randomWalkText,
    WalkRelation.jump => l10n.randomWalkJump,
  };
  return (
    label: label,
    evidence: edge.$3 == WalkRelation.tag ? '#${edge.$4}' : edge.$4
  );
}

class _WalkDock extends StatelessWidget {
  const _WalkDock({
    required this.action,
    required this.status,
    required this.onCenter,
    required this.onZoomOut,
    required this.onZoomIn,
  });

  final Widget action;
  final Widget? status;
  final VoidCallback onCenter;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final paper = RandomWalkCanvas.paperColor(theme);
    final l10n = AppLocalizationsSimple.of(context) ??
        AppLocalizationsSimple(Localizations.localeOf(context));
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [paper.withValues(alpha: 0), paper, paper],
          stops: const [0, 0.58, 1],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status case final feedback?)
              Center(
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                  child: feedback,
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Material(
                  color: colors.surface,
                  elevation: 2,
                  shadowColor: colors.shadow.withValues(alpha: 0.12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: colors.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l10n.randomWalkZoomOut,
                        onPressed: onZoomOut,
                        icon: const Icon(Icons.remove_rounded, size: 19),
                      ),
                      IconButton(
                        tooltip: l10n.randomWalkCenter,
                        onPressed: onCenter,
                        icon: const Icon(
                          Icons.center_focus_strong_rounded,
                          size: 19,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.randomWalkZoomIn,
                        onPressed: onZoomIn,
                        icon: const Icon(Icons.add_rounded, size: 19),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(child: action),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PaperPainter extends CustomPainter {
  const _PaperPainter(this.paper, this.dot);

  final Color paper;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final brush = Paint()..color = dot;
    for (var x = 12.0; x < size.width; x += 20) {
      for (var y = 12.0; y < size.height; y += 20) {
        canvas.drawCircle(Offset(x, y), 0.8, brush);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PaperPainter oldDelegate) =>
      paper != oldDelegate.paper || dot != oldDelegate.dot;
}

class _WalkCard extends StatelessWidget {
  const _WalkCard({
    required this.note,
    required this.selected,
    required this.visited,
    required this.reason,
    required this.onTap,
    required this.onRead,
    required this.fullNote,
  });

  final WalkNote note;
  final bool selected;
  final bool visited;
  final _WalkReason? reason;
  final VoidCallback? onTap;
  final VoidCallback? onRead;
  final Note? fullNote;

  static final _quoteMarker = RegExp(r'^>+\s*');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizationsSimple.of(context) ??
        AppLocalizationsSimple(Localizations.localeOf(context));
    final style = theme.textTheme;
    final date = MaterialLocalizations.of(context)
        .formatShortDate(note.createdAt.toLocal());
    final dark = theme.brightness == Brightness.dark;
    final card = dark ? const Color(0xFF242B28) : const Color(0xFFFFFEFA);
    final accent = dark ? const Color(0xFF86CFB4) : const Color(0xFF216B55);
    final preview = note.preview.replaceFirst(_quoteMarker, '');
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
      side: BorderSide(
        width: selected ? 1.8 : 1,
        color: selected
            ? accent
            : visited
                ? accent.withValues(alpha: 0.38)
                : colors.onSurface.withValues(alpha: 0.15),
      ),
    );
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: Material(
        color: selected
            ? Color.alphaBlend(accent.withValues(alpha: 0.07), card)
            : card,
        elevation: selected ? 4 : 1,
        shadowColor: colors.shadow.withValues(alpha: selected ? 0.23 : 0.10),
        shape: border,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: border,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        date,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.labelSmall?.copyWith(
                          color: colors.onSurface.withValues(alpha: 0.62),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (selected || visited)
                      Icon(
                        selected ? Icons.adjust_rounded : Icons.check_rounded,
                        size: 16,
                        color: accent,
                      ),
                  ],
                ),
                const SizedBox(height: 7),
                Expanded(
                  child: fullNote == null
                      ? Text(
                          preview.isEmpty ? l10n.randomWalkAttachment : preview,
                          maxLines: selected && reason == null ? 4 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: style.bodyMedium?.copyWith(
                            height: 1.4,
                            color: colors.onSurface,
                          ),
                        )
                      : SingleChildScrollView(
                          primary: false,
                          child: MemosMarkdownRenderer.fromNote(
                            note: fullNote!,
                            serverUrl: context
                                .read<AppProvider>()
                                .appConfig
                                .memosApiUrl,
                            gridImages: true,
                          ),
                        ),
                ),
                if (reason case final reason?) ...[
                  const SizedBox(height: 5),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: reason.label,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (reason.evidence.isNotEmpty)
                              TextSpan(
                                text: selected
                                    ? '\n${reason.evidence}'
                                    : ' · ${reason.evidence}',
                                style: selected
                                    ? TextStyle(color: colors.onSurface)
                                    : null,
                              ),
                          ],
                        ),
                        maxLines: selected ? 4 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: (selected ? style.bodySmall : style.labelSmall)
                            ?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
                if (onRead != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: onRead,
                      icon: Icon(
                        fullNote == null
                            ? Icons.expand_more_rounded
                            : Icons.expand_less_rounded,
                        size: 17,
                      ),
                      label:
                          Text(fullNote == null ? l10n.expand : l10n.collapse),
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(54, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WalkEdgesPainter extends CustomPainter {
  _WalkEdgesPainter({
    required this.cards,
    required this.edges,
    required this.walked,
    required this.lineColor,
    required this.pathColor,
  });

  final Map<String, Rect> cards;
  final List<WalkConnection> edges;
  final Set<(String, String)> walked;
  final Color lineColor;
  final Color pathColor;

  bool _active(String from, String to) =>
      walked.contains((from, to)) || walked.contains((to, from));

  Path _curve(Rect from, Rect to) {
    final start = from.centerRight;
    final end = to.centerLeft;
    final path = Path()..moveTo(start.dx, start.dy);
    final dy = end.dy - start.dy;
    if (dy.abs() < 1) {
      return path..lineTo(end.dx, end.dy);
    }
    final middle = (start.dx + end.dx) / 2;
    final radius = min(12.0, min((end.dx - start.dx) / 2, dy.abs() / 2));
    final verticalRadius = dy.sign * radius;
    return path
      ..lineTo(middle - radius, start.dy)
      ..quadraticBezierTo(middle, start.dy, middle, start.dy + verticalRadius)
      ..lineTo(middle, end.dy - verticalRadius)
      ..quadraticBezierTo(middle, end.dy, middle + radius, end.dy)
      ..lineTo(end.dx, end.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final brush = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final ordered = [
      ...edges.where((edge) => !_active(edge.$1, edge.$2)),
      ...edges.where((edge) => _active(edge.$1, edge.$2)),
    ];
    for (final (from, to, kind, _) in ordered) {
      final active = _active(from, to);
      final path = _curve(cards[from]!, cards[to]!);
      brush
        ..color = active ? pathColor : lineColor
        ..strokeWidth = active ? 2.8 : 1.5;
      if (kind == WalkRelation.jump) {
        for (final metric in path.computeMetrics()) {
          for (var offset = 0.0; offset < metric.length; offset += 12) {
            canvas.drawPath(
              metric.extractPath(offset, min(offset + 6, metric.length)),
              brush,
            );
          }
        }
      } else {
        canvas.drawPath(path, brush);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WalkEdgesPainter oldDelegate) =>
      oldDelegate.cards != cards ||
      oldDelegate.edges != edges ||
      oldDelegate.walked != walked ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.pathColor != pathColor;
}
