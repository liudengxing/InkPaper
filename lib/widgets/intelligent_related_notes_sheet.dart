import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:inkpaper/l10n/app_localizations_simple.dart';
import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/random_walk_index.dart';
import 'package:inkpaper/services/user_behavior_service.dart';

typedef RelatedNoteItem = ({Note note, RelatedNoteLink link, String preview});

class IntelligentRelatedNotesSheet extends StatelessWidget {
  const IntelligentRelatedNotesSheet({required this.items, super.key});

  final List<RelatedNoteItem> items;

  static Future<void> show(BuildContext context, List<RelatedNoteItem> items) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (context) => IntelligentRelatedNotesSheet(items: items),
      );

  static String _reason(RelatedNoteLink link, AppLocalizationsSimple l10n) {
    final label = switch (link.kind) {
      RelatedNoteEvidence.reference => l10n.randomWalkReference,
      RelatedNoteEvidence.backlink => l10n.randomWalkBacklink,
      RelatedNoteEvidence.text => l10n.randomWalkText,
      RelatedNoteEvidence.source => l10n.relatedNotesSameSource,
      RelatedNoteEvidence.tag => l10n.randomWalkTag,
    };
    final evidence = link.kind == RelatedNoteEvidence.tag
        ? '#${link.evidence}'
        : link.evidence;
    return evidence.isEmpty ? label : '$label · $evidence';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizationsSimple.of(context) ??
        AppLocalizationsSimple(Localizations.localeOf(context));
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.68,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(l10n.relatedNotes, style: theme.textTheme.titleLarge),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  indent: 20,
                  endIndent: 20,
                ),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    title: Text(
                      item.preview.isEmpty
                          ? l10n.randomWalkAttachment
                          : item.preview,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _reason(item.link, l10n),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await UserBehaviorService().recordClick(
                        noteId: item.note.id,
                        noteTags: item.note.tags,
                        relationType: item.link.kind.name,
                        source: 'related_sheet',
                      );
                      if (!context.mounted) {
                        return;
                      }
                      final router = GoRouter.of(context);
                      Navigator.of(context).pop();
                      await router.push('/note/${item.note.id}');
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
