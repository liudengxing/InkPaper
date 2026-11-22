import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/providers/app_provider.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/widgets/random_walk_canvas.dart';
import 'package:inkpaper/widgets/random_walk_recap.dart';
import 'package:provider/provider.dart';

typedef _WalkStep = ({Note note, WalkConnection? via});

class RandomWalkScreen extends StatefulWidget {
  const RandomWalkScreen({super.key});

  @override
  State<RandomWalkScreen> createState() => _RandomWalkScreenState();
}

class _RandomWalkScreenState extends State<RandomWalkScreen> {
  final _random = Random();
  final _invalid = <String>{};
  final _path = <_WalkStep>[];
  List<WalkConnection> _choices = const [];
  RandomWalkIndex? _index;
  var _loading = true;
  var _busy = false;
  var _failed = false;

  AppProvider get _provider => context.read<AppProvider>();

  AppLocalizationsSimple get _l10n =>
      AppLocalizationsSimple.of(context) ??
      AppLocalizationsSimple(Localizations.localeOf(context));

  Set<String> get _pathIds => {for (final step in _path) step.note.id};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final notes = await _provider.loadRandomWalkNotes();
      final index =
          await compute(RandomWalkIndex.new, notes, debugLabel: 'random-walk');
      if (!mounted) {
        return;
      }
      _index = index;
      final seed = await _randomNote();
      if (!mounted) {
        return;
      }
      final choices = seed == null
          ? <WalkConnection>[]
          : await _related(seed.id, {seed.id});
      if (!mounted) {
        return;
      }
      setState(() {
        if (seed != null) {
          _path.add((note: seed, via: null));
        }
        _choices = choices;
        _loading = false;
      });
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

  Future<List<WalkConnection>> _related(String id, Set<String> path) async {
    final choices =
        _index!.related(id, shown: path, excluded: {...path, ..._invalid});
    final provider = _provider;
    final notes = await Future.wait(
      choices.map((edge) => provider.loadRandomWalkNote(edge.$2)),
    );
    final available = <WalkConnection>[];
    for (var i = 0; i < choices.length; i++) {
      if (notes[i] == null) {
        _invalid.add(choices[i].$2);
      } else {
        available.add(choices[i]);
      }
    }
    return available;
  }

  Future<Note?> _randomNote() async {
    final excluded = {..._pathIds, ..._invalid};
    final ids = _index!.ids.where((id) => !excluded.contains(id)).toList()
      ..shuffle(_random);
    final provider = _provider;
    for (final id in ids) {
      final note = await provider.loadRandomWalkNote(id);
      if (note != null || !mounted) {
        return note;
      }
      _invalid.add(id);
    }
    return null;
  }

  Future<void> _advance(Note note, WalkConnection? via) async {
    final choices = await _related(note.id, {..._pathIds, note.id});
    if (mounted) {
      setState(() {
        _path.add((note: note, via: via));
        _choices = choices;
      });
    }
  }

  void _select(String id) {
    if (_path.length > 1 && id == _path[_path.length - 2].note.id) {
      _back();
      return;
    }
    final edge = _choices.where((edge) => edge.$2 == id).firstOrNull;
    if (edge == null) {
      return;
    }
    _perform(() async {
      final note = await _provider.loadRandomWalkNote(id);
      if (!mounted) {
        return;
      }
      if (note == null) {
        _invalid.add(id);
        setState(
          () => _choices = _choices.where((edge) => edge.$2 != id).toList(),
        );
        _message(_l10n.randomWalkMissing);
        return;
      }
      await _advance(note, edge);
    });
  }

  void _back() {
    _perform(() async {
      for (var i = _path.length - 2; i >= 0; i--) {
        final step = _path[i];
        final note = await _provider.loadRandomWalkNote(step.note.id);
        if (!mounted) {
          return;
        }
        if (note == null) {
          _invalid.add(step.note.id);
          continue;
        }
        final ancestors = _path.take(i + 1).map((step) => step.note.id).toSet();
        final choices = await _related(note.id, ancestors);
        if (mounted) {
          setState(() {
            _path
              ..removeRange(i, _path.length)
              ..add((note: note, via: step.via));
            _choices = choices;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          final current = _path.last.note;
          _path
            ..clear()
            ..add((note: current, via: null));
        });
        _message(_l10n.randomWalkMissing);
      }
    });
  }

  void _jump() {
    _perform(() async {
      final note = await _randomNote();
      if (note == null || !mounted) {
        return;
      }
      final previous = _path.lastOrNull?.note.id;
      await _advance(
        note,
        previous == null ? null : (previous, note.id, WalkRelation.jump, ''),
      );
    });
  }

  Future<void> _showRecap({bool closing = false}) async {
    if (_path.isEmpty || (closing && _path.length == 1)) {
      Navigator.of(context).maybePop();
      return;
    }
    final notes = _path.map((step) => step.note).toList();
    final exit = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => RandomWalkRecapSheet(notes: notes),
    );
    if (mounted && (exit ?? false)) {
      Navigator.of(context).pop();
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final theme = Theme.of(context);
    final pathIds = _pathIds;
    final canJump = _index?.ids
            .any((id) => !pathIds.contains(id) && !_invalid.contains(id)) ??
        false;
    final focus = _path.lastOrNull?.note;
    final paper = RandomWalkCanvas.paperColor(theme);
    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          l10n.randomWalk,
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          tooltip: l10n.close,
          onPressed: () => _showRecap(closing: true),
          icon: const Icon(Icons.close_rounded),
        ),
        actions: [
          IconButton(
            tooltip: l10n.randomWalkBack,
            onPressed: _busy || _path.length < 2 ? null : _back,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: l10n.randomWalkJump,
            onPressed: _busy || _loading || _failed || !canJump ? null : _jump,
            icon: const Icon(Icons.shuffle_rounded),
          ),
        ],
      ),
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
          (final note?, _, _) => RandomWalkCanvas(
              notes: [
                for (final step in _path) _index!.note(step.note.id)!,
                for (final choice in _choices) _index!.note(choice.$2)!,
              ],
              edges: [
                for (final step in _path)
                  if (step.via case final edge?) edge,
                ..._choices,
              ],
              path: pathIds.toList(),
              current: note,
              onSelect: _select,
              action: TextButton.icon(
                onPressed: _busy ? null : _showRecap,
                icon: const Icon(Icons.summarize_outlined, size: 19),
                label: Text(l10n.randomWalkRecap),
              ),
              status: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _choices.isEmpty
                      ? Text(l10n.randomWalkEnd)
                      : null,
            ),
          _ => Center(child: Text(l10n.randomWalkEmpty)),
        },
      ),
    );
  }
}
