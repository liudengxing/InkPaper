import 'package:flutter/material.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';

class RandomWalkRecapSheet extends StatelessWidget {
  const RandomWalkRecapSheet({required this.notes, super.key});

  final List<Note> notes;

  static DateTime _day(DateTime date) {
    final local = date.toLocal();
    return DateTime.utc(local.year, local.month, local.day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizationsSimple.of(context) ??
        AppLocalizationsSimple(Localizations.localeOf(context));
    final dates = MaterialLocalizations.of(context);
    var firstDate = _day(notes.first.createdAt);
    var lastDate = firstDate;
    var lastStepDate = firstDate;
    var longestJump = -1;
    var longestStep = 0;
    final previews = <String>[];
    var charCount = 0;
    for (var i = 0; i < notes.length; i++) {
      final note = notes[i];
      final day = _day(note.createdAt);
      if (day.isBefore(firstDate)) {
        firstDate = day;
      }
      if (day.isAfter(lastDate)) {
        lastDate = day;
      }
      final jump = day.difference(lastStepDate).inDays.abs();
      if (i > 0 && jump > longestJump) {
        longestJump = jump;
        longestStep = i;
      }
      lastStepDate = day;
      final text = MemosContentHelper.previewVisibleText(note.content);
      charCount += text.replaceAll(RegExp(r'\s+'), '').runes.length;
      previews.add(text.isEmpty ? l10n.randomWalkAttachment : text);
    }
    final days = lastDate.difference(firstDate).inDays;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.80),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.randomWalkRecap, style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.randomWalkRecapRange,
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.randomWalkRecapDays(days),
                        style: theme.textTheme.displaySmall?.copyWith(
                          color: colors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${dates.formatShortDate(firstDate)}  →  ${dates.formatShortDate(lastDate)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 17),
              _RecapEndpoint(
                label: l10n.randomWalkRecapFrom,
                value: previews.first,
              ),
              if (notes.length > 1) ...[
                const SizedBox(height: 10),
                _RecapEndpoint(
                  label: l10n.randomWalkRecapTo,
                  value: previews.last,
                ),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Divider(),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _RecapStat(
                      label: l10n.randomWalkRecapNotes,
                      value: '${notes.length}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _RecapStat(
                      label: l10n.randomWalkRecapChars,
                      value: '$charCount',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _RecapStat(
                      label: l10n.randomWalkRecapFarthest,
                      value: longestStep == 0
                          ? '—'
                          : l10n.randomWalkRecapStep(longestStep),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(l10n.randomWalkExit),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.randomWalkContinue),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecapEndpoint extends StatelessWidget {
  const _RecapEndpoint({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 3),
        Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _RecapStat extends StatelessWidget {
  const _RecapStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
