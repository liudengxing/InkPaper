import 'dart:math';

import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/services/random_walk_index.dart';

class RandomWalkCanvas extends StatefulWidget {
  const RandomWalkCanvas({
    required this.notes,
    required this.edges,
    required this.path,
    required this.focus,
    required this.centerRequest,
    required this.onSelect,
    super.key,
  });

  final List<WalkNote> notes;
  final List<WalkConnection> edges;
  final List<String> path;
  final String focus;
  final int centerRequest;
  final ValueChanged<String> onSelect;

  @override
  State<RandomWalkCanvas> createState() => _RandomWalkCanvasState();
}

class _RandomWalkCanvasState extends State<RandomWalkCanvas> {
  static const _cardSize = Size(140, 108);
  static const _spacing = Offset(174, 144);
  static const _directions = [
    Offset(1, 0),
    Offset(0, 1),
    Offset(-1, 0),
    Offset(0, -1),
    Offset(1, 1),
    Offset(-1, 1),
    Offset(-1, -1),
    Offset(1, -1),
  ];

  final _camera = TransformationController();
  final _positions = <String, Offset>{};
  Size? _viewSize;
  Offset? _origin;
  int? _centeredRequest;

  @override
  void initState() {
    super.initState();
    _updatePositions();
  }

  @override
  void didUpdateWidget(RandomWalkCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updatePositions();
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _updatePositions() {
    final ids = widget.notes.map((note) => note.id).toSet();
    _positions.removeWhere((id, _) => !ids.contains(id));
    final occupied = _positions.values.toSet();
    final parents = {
      for (final edge in widget.edges.reversed) edge.$2: edge.$1,
    };
    for (final id in ids) {
      if (_positions.containsKey(id)) {
        continue;
      }
      final base = _positions[parents[id]] ?? Offset.zero;
      final slot = occupied.isEmpty ? base : _findSlot(base, occupied);
      _positions[id] = slot;
      occupied.add(slot);
    }
  }

  Offset _findSlot(Offset base, Set<Offset> occupied) {
    for (var ring = 1;; ring++) {
      for (final direction in _directions) {
        final position = base +
            Offset(
              direction.dx * ring * _spacing.dx,
              direction.dy * ring * _spacing.dy,
            );
        if (!occupied.contains(position)) {
          return position;
        }
      }
    }
  }

  void _updateCamera(Size viewport, Offset origin, Offset focalPoint) {
    final previousOrigin = _origin;
    final firstFrame = _viewSize == null;
    final shouldCenter = firstFrame ||
        _viewSize != viewport ||
        _centeredRequest != widget.centerRequest;
    if (!shouldCenter && previousOrigin == origin) {
      return;
    }
    _viewSize = viewport;
    _origin = origin;
    _centeredRequest = widget.centerRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _origin != origin) {
        return;
      }
      final scale = firstFrame
          ? (viewport.width / 510).clamp(0.62, 1.0)
          : _camera.value.getMaxScaleOnAxis();
      if (shouldCenter) {
        _camera.value = Matrix4.diagonal3Values(scale, scale, scale)
          ..setTranslationRaw(
            viewport.width / 2 - focalPoint.dx * scale,
            viewport.height / 2 - focalPoint.dy * scale,
            0,
          );
      } else {
        final translation = _camera.value.getTranslation();
        final delta = origin - previousOrigin!;
        _camera.value = Matrix4.copy(_camera.value)
          ..setTranslationRaw(
            translation.x - delta.dx * scale,
            translation.y - delta.dy * scale,
            0,
          );
      }
    });
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
          _updateCamera(viewport, origin, points[widget.focus]!);
          final theme = Theme.of(context);
          final l10n = AppLocalizationsSimple.of(context) ??
              AppLocalizationsSimple(Localizations.localeOf(context));
          final connectedToFocus = <String, String>{};
          for (final edge in widget.edges) {
            if (edge.$1 == widget.focus) {
              connectedToFocus[edge.$2] = _edgeLabel(l10n, edge.$3, edge.$4);
            } else if (edge.$2 == widget.focus) {
              final kind = switch (edge.$3) {
                WalkRelation.reference => WalkRelation.backlink,
                WalkRelation.backlink => WalkRelation.reference,
                final kind => kind,
              };
              connectedToFocus[edge.$1] = _edgeLabel(l10n, kind, edge.$4);
            }
          }
          final walked = <(String, String)>{
            for (var i = 1; i < widget.path.length; i++)
              (widget.path[i - 1], widget.path[i]),
          };
          return ColoredBox(
            color: theme.colorScheme.surfaceContainerLowest,
            child: InteractiveViewer.builder(
              minScale: 0.42,
              maxScale: 1.65,
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
                      points: points,
                      edges: widget.edges,
                      walked: walked,
                      lineColor: theme.colorScheme.outline,
                      pathColor: theme.colorScheme.primary,
                    ),
                    child: Stack(
                      children: [
                        for (final note in widget.notes)
                          if (note.id == widget.focus ||
                              visible.contains(points[note.id]!))
                            Positioned.fromRect(
                              key: ValueKey(note.id),
                              rect: Rect.fromCenter(
                                center: points[note.id]!,
                                width: _cardSize.width,
                                height: _cardSize.height,
                              ),
                              child: _WalkCard(
                                note: note,
                                selected: note.id == widget.focus,
                                reason: connectedToFocus[note.id],
                                onTap: () => widget.onSelect(note.id),
                              ),
                            ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
}

String _edgeLabel(
  AppLocalizationsSimple l10n,
  WalkRelation kind,
  String evidence,
) {
  final tag = l10n.randomWalkTag;
  final text = l10n.randomWalkText;
  return switch (kind) {
    WalkRelation.reference => l10n.randomWalkReference,
    WalkRelation.backlink => l10n.randomWalkBacklink,
    WalkRelation.tag => '$tag #$evidence',
    WalkRelation.text => '$text · $evidence',
    WalkRelation.jump => l10n.randomWalkJump,
  };
}

class _WalkCard extends StatelessWidget {
  const _WalkCard({
    required this.note,
    required this.selected,
    required this.reason,
    required this.onTap,
  });

  final WalkNote note;
  final bool selected;
  final String? reason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizationsSimple.of(context) ??
        AppLocalizationsSimple(Localizations.localeOf(context));
    final style = theme.textTheme;
    final date = MaterialLocalizations.of(context)
        .formatShortDate(note.createdAt.toLocal());
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side:
          BorderSide(color: selected ? colors.primary : colors.outlineVariant),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
        shape: border,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: border,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  date,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.labelSmall,
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: Text(
                    note.preview.isEmpty
                        ? l10n.randomWalkAttachment
                        : note.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style.bodyMedium,
                  ),
                ),
                if (reason case final text?) ...[
                  const SizedBox(height: 4),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style.labelSmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
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
    required this.points,
    required this.edges,
    required this.walked,
    required this.lineColor,
    required this.pathColor,
  });

  final Map<String, Offset> points;
  final List<WalkConnection> edges;
  final Set<(String, String)> walked;
  final Color lineColor;
  final Color pathColor;

  @override
  void paint(Canvas canvas, Size size) {
    final brush = Paint()..strokeCap = StrokeCap.round;
    for (final (from, to, kind, _) in edges) {
      final a = points[from]!;
      final b = points[to]!;
      final active = walked.contains((from, to)) || walked.contains((to, from));
      brush
        ..color = active ? pathColor : lineColor.withValues(alpha: 0.55)
        ..strokeWidth = active ? 2 : 1.2;
      if (kind == WalkRelation.jump) {
        final distance = (b - a).distance;
        for (var offset = 0.0; offset < distance; offset += 12) {
          canvas.drawLine(
            Offset.lerp(a, b, offset / distance)!,
            Offset.lerp(a, b, min(offset + 6, distance) / distance)!,
            brush,
          );
        }
      } else {
        canvas.drawLine(a, b, brush);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WalkEdgesPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.edges != edges ||
      oldDelegate.walked != walked ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.pathColor != pathColor;
}
