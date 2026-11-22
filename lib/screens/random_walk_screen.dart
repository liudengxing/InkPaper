import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/widgets/random_walk_canvas.dart';
import 'package:provider/provider.dart';

class RandomWalkScreen extends StatefulWidget {
  const RandomWalkScreen({super.key});

  @override
  State<RandomWalkScreen> createState() => _RandomWalkScreenState();
}

class _RandomWalkScreenState extends State<RandomWalkScreen> {
  final _random = Random();
  final _shown = <String>{};
  final _invalid = <String>{};
  final _expanded = <String>{};
  final _history = <String>[];
  final _edges = <WalkConnection>[];
  RandomWalkIndex? _index;
  String? _focus;
  var _centerRequest = 0;
  var _loading = true;
  var _busy = false;
  var _failed = false;

  AppProvider get _provider => context.read<AppProvider>();

  AppLocalizationsSimple get _l10n =>
      AppLocalizationsSimple.of(context) ??
      AppLocalizationsSimple(Localizations.localeOf(context));

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<RandomWalkIndex> _loadIndex() async {
    final notes = await _provider.loadRandomWalkNotes();
    return compute(RandomWalkIndex.new, notes, debugLabel: 'random-walk');
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final index = await _loadIndex();
      if (!mounted) {
        return;
      }
      setState(() {
        _index = index;
        if (index.ids.isNotEmpty) {
          final root = index.ids.elementAt(_random.nextInt(index.ids.length));
          _focus = root;
          _shown.add(root);
        }
        _loading = false;
      });
      if (_focus case final root?) {
        await _perform(() => _expand(root));
      }
    } on Object catch (error) {
      debugPrint('RandomWalk: $error');
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on Object catch (error) {
      debugPrint('RandomWalk: $error');
      if (mounted) {
        _message(_l10n.randomWalkError);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _expand(String id, {bool center = true}) async {
    if (_expanded.contains(id)) {
      return;
    }
    final candidates = _index!.related(
      id,
      shown: _shown,
      excluded: {
        ..._invalid,
        for (final edge in _edges)
          if (edge.$1 == id) edge.$2 else if (edge.$2 == id) edge.$1,
      },
    );
    final records = await Future.wait(
      candidates.map((edge) => _provider.loadRandomWalkNote(edge.$2)),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _expanded.add(id);
      for (var i = 0; i < candidates.length; i++) {
        final edge = candidates[i];
        if (records[i] == null) {
          _remove(edge.$2);
        } else {
          _shown.add(edge.$2);
          _edges.add(edge);
        }
      }
      if (center) {
        _centerRequest++;
      }
    });
  }

  void _remove(String id) {
    _invalid.add(id);
    _shown.remove(id);
    _expanded.remove(id);
    _history.removeWhere((step) => step == id);
    for (final edge in _edges) {
      if (edge.$2 == id) {
        _expanded.remove(edge.$1);
      }
    }
    _edges.removeWhere((edge) => edge.$1 == id || edge.$2 == id);
    if (_focus == id) {
      _focus = _history.isNotEmpty ? _history.removeLast() : _shown.firstOrNull;
      _centerRequest++;
    }
  }

  void _moveTo(String id) {
    if (_focus case final previous? when previous != id) {
      _history.add(previous);
    }
    _focus = id;
    _centerRequest++;
  }

  void _select(String id) {
    if (_busy || (id == _focus && _expanded.contains(id))) {
      return;
    }
    _perform(() async {
      final note = await _provider.loadRandomWalkNote(id);
      if (!mounted) {
        return;
      }
      if (note == null) {
        setState(() => _remove(id));
        _message(_l10n.randomWalkMissing);
        return;
      }
      setState(() => _moveTo(id));
      await _expand(id);
    });
  }

  void _back() {
    _perform(() async {
      while (_history.isNotEmpty) {
        final id = _history.last;
        final note = await _provider.loadRandomWalkNote(id);
        if (!mounted) {
          return;
        }
        if (note == null) {
          setState(() => _remove(id));
        } else {
          setState(() {
            _focus = _history.removeLast();
            _centerRequest++;
          });
          await _expand(id);
          return;
        }
      }
    });
  }

  void _jump() {
    _perform(() async {
      final choices = _index!.ids
          .where((id) => !_shown.contains(id) && !_invalid.contains(id))
          .toList()
        ..shuffle(_random);
      for (final id in choices) {
        final note = await _provider.loadRandomWalkNote(id);
        if (!mounted) {
          return;
        }
        if (note == null) {
          setState(() => _remove(id));
          continue;
        }
        setState(() {
          if (_focus case final from?) {
            _edges.add((from, id, WalkRelation.jump, ''));
          }
          _shown.add(id);
          _moveTo(id);
        });
        await _expand(id);
        return;
      }
    });
  }

  void _openNote(String id) {
    _perform(() async {
      final note = await _provider.loadRandomWalkNote(id);
      if (!mounted) {
        return;
      }
      if (note == null) {
        setState(() => _remove(id));
        _message(_l10n.randomWalkMissing);
        return;
      }
      await context.pushNamed<void>('noteDetail', pathParameters: {'id': id});
      if (!mounted) {
        return;
      }
      final newIndex = await _loadIndex();
      if (!mounted) {
        return;
      }
      final affected =
          _shown.where((key) => newIndex.note(key) == null).toList();
      final changed = !newIndex.sameEvidence(id, _index!);
      setState(() {
        for (final key in affected) {
          _remove(key);
        }
        _index = newIndex;
        _invalid.removeWhere((key) => newIndex.note(key) != null);
        final removedEdges =
            _edges.where((edge) => !newIndex.retains(edge)).toList();
        for (final edge in removedEdges) {
          _expanded.remove(edge.$1);
        }
        _edges.removeWhere(removedEdges.contains);
        if (changed) {
          _expanded.remove(id);
        }
      });
      if (_focus case final current?) {
        await _expand(current, center: current != id);
      }
    });
  }

  void _message(String text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final focus = _focus;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.randomWalk)),
      body: SafeArea(
        child: switch ((focus, _loading, _failed)) {
          (_, true, _) => const Center(child: CircularProgressIndicator()),
          (_, _, true) => Center(
              child: TextButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.randomWalkError),
              ),
            ),
          (final focus?, _, _) => _buildWalk(focus, l10n),
          _ when _index!.ids.any((id) => !_invalid.contains(id)) =>
            Center(child: _jumpButton(l10n)),
          _ => Center(child: Text(l10n.randomWalkEmpty)),
        },
      ),
    );
  }

  Widget _jumpButton(AppLocalizationsSimple l10n) => TextButton.icon(
        onPressed: _busy ? null : _jump,
        icon: const Icon(Icons.shuffle_rounded),
        label: Text(l10n.randomWalkJump),
      );

  Widget _buildWalk(String focus, AppLocalizationsSimple l10n) {
    final hasNewBranch = _edges.any(
      (edge) =>
          (edge.$1 == focus || edge.$2 == focus) &&
          edge.$3 != WalkRelation.jump &&
          !_expanded.contains(edge.$1 == focus ? edge.$2 : edge.$1),
    );
    final reachedEnd = !_busy && _expanded.contains(focus) && !hasNewBranch;
    final canJump = reachedEnd &&
        _index!.ids.any((id) => !_shown.contains(id) && !_invalid.contains(id));
    return Column(
      children: [
        Expanded(
          child: RandomWalkCanvas(
            notes: [for (final id in _shown) _index!.note(id)!],
            edges: List.of(_edges),
            path: [..._history, focus],
            focus: focus,
            centerRequest: _centerRequest,
            onSelect: _select,
          ),
        ),
        SizedBox(
          height: 44,
          child: switch ((canJump, reachedEnd, _busy)) {
            (true, _, _) => _jumpButton(l10n),
            (_, true, _) => Center(child: Text(l10n.randomWalkEnd)),
            (_, _, true) => const Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            _ => const SizedBox.shrink(),
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: l10n.randomWalkBack,
                onPressed: _busy || _history.isEmpty ? null : _back,
                icon: const Icon(Icons.undo_rounded),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _busy ? null : () => _openNote(focus),
                child: Text(l10n.randomWalkOpen),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: l10n.randomWalkCenter,
                onPressed: () => setState(() => _centerRequest++),
                icon: const Icon(Icons.center_focus_strong_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
