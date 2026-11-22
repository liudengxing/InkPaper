import 'dart:math';

import 'package:inkpaper/models/note_model.dart';
import 'package:inkpaper/services/weread_note_builder.dart';
import 'package:inkpaper/utils/memos_content_helper.dart';
import 'package:inkpaper/utils/tag_utils.dart' as tags;
import 'package:inkpaper/utils/text_analysis_utils.dart';

enum WalkRelation { reference, backlink, tag, text, jump }

enum RelatedNoteEvidence { reference, backlink, text, source, tag }

typedef RelatedNoteLink = ({
  String id,
  RelatedNoteEvidence kind,
  String evidence,
});

typedef WalkConnection = (
  String from,
  String to,
  WalkRelation kind,
  String evidence
);

typedef WalkNote = ({String id, String preview, DateTime createdAt});

/// 每次漫步建一次索引，只检索和当前笔记共享线索的局部邻居。
class RandomWalkIndex {
  RandomWalkIndex(List<Note> notes) {
    final remoteIds = {
      for (final note in notes)
        if (note.remoteId case final id?) id: note.id,
    };
    var totalTerms = 0;
    for (final note in notes) {
      final plainText = _plainText(note.content);
      final preview = plainText.replaceAll(_spaces, ' ');
      final noteTags = {
        ...note.tags,
        ...tags.extractTagsFromContent(note.content),
      }
          .map((tag) => tag.trim().replaceFirst(_leadingHashes, '').trim())
          .map((tag) => tag.toLowerCase())
          .where((tag) => tag.isNotEmpty)
          .toSet();
      final body = plainText.replaceAll(_tagPattern, ' ');
      final terms = TextAnalysisUtils.extractTerms(body);
      final frequencies = <String, int>{};
      for (final term in terms) {
        frequencies.update(term, (count) => count + 1, ifAbsent: () => 1);
      }
      final compact = preview.runes.take(180).toList();
      _documents[note.id] = _WalkDocument(
        note: (
          id: note.id,
          preview: String.fromCharCodes(compact),
          createdAt: note.createdAt
        ),
        tags: noteTags,
        terms: frequencies.keys.toSet(),
        body: body,
        length: terms.length,
        isWeRead: noteTags.contains(WeReadNoteBuilder.sourceTag) ||
            WeReadNoteBuilder.isWeReadNoteId(note.id),
      );
      totalTerms += terms.length;
      for (final tag in noteTags) {
        (_tags[tag] ??= []).add(note.id);
      }
      for (final entry in frequencies.entries) {
        (_terms[entry.key] ??= {})[note.id] = entry.value;
      }
      for (final url in _sourceUrls(note.content)) {
        (_sources[url] ??= <String>{}).add(note.id);
        (_sourcesByNote[note.id] ??= <String>{}).add(url);
      }
    }
    _averageLength = max(1, totalTerms / max(1, _documents.length));

    for (final note in notes) {
      for (final match in _internalLinks.allMatches(note.content)) {
        final rawId = match.group(1)!.split('?').first.trim();
        final target = _documents.containsKey(rawId) ? rawId : remoteIds[rawId];
        if (target != null && target != note.id) {
          _link(note.id, target);
        }
      }
      for (final relation in note.relations) {
        final rawId = relation['relatedMemoId']?.toString();
        if (rawId == null) {
          continue;
        }
        final id = _documents.containsKey(rawId) ? rawId : remoteIds[rawId];
        if (id == null || id == note.id) {
          continue;
        }
        switch (relation['type']) {
          case 'REFERENCE':
            _link(note.id, id);
          case 'REFERENCED_BY':
            _link(id, note.id);
        }
      }
    }
  }

  static final _tagPattern = tags.getTagRegex();
  static final _leadingHashes = RegExp('^#+');
  static final _sourceUrl =
      RegExp(r'https?://[^\s\])>"。，、；！？]+', caseSensitive: false);
  static final _urlTrailingPunctuation = RegExp(r'[.,;!?]+$');
  static final _links = RegExp(r'\[([^\]]+)\]\([^)]+\)');
  static final _internalLinks = RegExp(r'\[\[([^\]]+)\]\]');
  static final _urls = RegExp(r'https?://[^\s]+');
  static final _html = RegExp('<[^>]+>');
  static final _spaces = RegExp(r'\s+');
  static final _clauseBoundary = RegExp(r'[，。！？；、!?;\r\n]+|[.,](?:\s+|$)');
  static final _chineseTerm = RegExp(r'^[\u4e00-\u9fa5]+$');
  static final _wordCharacter =
      RegExp(r'[\p{Script=Latin}\p{M}\p{N}]', unicode: true);

  static String _plainText(String text) => text
      .replaceAll(MemosContentHelper.markdownMediaRegex, ' ')
      .replaceAllMapped(_links, (match) => match.group(1)!)
      .replaceAll(_internalLinks, ' ')
      .replaceAll(_urls, ' ')
      .replaceAll(_html, ' ')
      .trim();

  final _documents = <String, _WalkDocument>{};
  final _tags = <String, List<String>>{};
  final _terms = <String, Map<String, int>>{};
  final _linksById = <String, Map<String, WalkRelation>>{};
  final _sources = <String, Set<String>>{};
  final _sourcesByNote = <String, Set<String>>{};
  late final double _averageLength;

  Iterable<String> get ids => _documents.keys;

  WalkNote? note(String id) => _documents[id]?.note;

  void _link(String from, String to) {
    (_linksById[from] ??= {})[to] = WalkRelation.reference;
    (_linksById[to] ??= {}).putIfAbsent(from, () => WalkRelation.backlink);
  }

  double _idf(int frequency) =>
      log(1 + (_documents.length - frequency + 0.5) / (frequency + 0.5));

  static Iterable<String> _sourceUrls(String content) sync* {
    final text = content.replaceAll(MemosContentHelper.markdownMediaRegex, ' ');
    for (final match in _sourceUrl.allMatches(text)) {
      final url = Uri.tryParse(
        match.group(0)!.replaceFirst(_urlTrailingPunctuation, ''),
      );
      if (url != null && url.host.isNotEmpty) {
        yield url.removeFragment().toString();
      }
    }
  }

  /// 相关笔记优先返回显式引用，再按正文、共同网页和少量罕见标签排序。
  List<RelatedNoteLink> rankRelatedNotes(String id, {int limit = 12}) {
    final source = _documents[id];
    if (source == null || limit <= 0) {
      return [];
    }
    final links = _linksById[id] ?? const <String, WalkRelation>{};
    final direct = links.keys.toList()..sort();
    final picks = <RelatedNoteLink>[
      for (final target in direct.take(limit))
        (
          id: target,
          kind: links[target] == WalkRelation.reference
              ? RelatedNoteEvidence.reference
              : RelatedNoteEvidence.backlink,
          evidence: '',
        ),
    ];
    if (picks.length == limit) {
      return picks;
    }

    const shown = <String>{};
    final excluded = links.keys.toSet();
    final scores = <String, _WalkScore>{};
    _scoreTags(source, shown, excluded, scores, relatedNotes: true);
    final query = _scoreText(source, shown, excluded, scores);
    final sameSources = <String, String>{};
    for (final url in _sourcesByNote[id] ?? const <String>{}) {
      for (final target in _sources[url]!) {
        if (target != id && !excluded.contains(target)) {
          sameSources.putIfAbsent(target, () => url);
          scores.putIfAbsent(target, _WalkScore.new);
        }
      }
    }

    RelatedNoteEvidence evidenceKind(MapEntry<String, _WalkScore> candidate) {
      if (candidate.value.hasTextMatch) {
        return RelatedNoteEvidence.text;
      }
      return sameSources.containsKey(candidate.key)
          ? RelatedNoteEvidence.source
          : RelatedNoteEvidence.tag;
    }

    double relevance(MapEntry<String, _WalkScore> candidate) {
      final score = candidate.value;
      return score.hasTextMatch
          ? log(1 + score.textScore) +
              min(0.15, score.tagScore * 0.04) +
              (sameSources.containsKey(candidate.key) ? 0.1 : 0)
          : score.tagScore;
    }

    final ranked = scores.entries
        .where(
          (entry) =>
              entry.value.hasTextMatch ||
              sameSources.containsKey(entry.key) ||
              entry.value.tag != null,
        )
        .toList()
      ..sort((a, b) {
        final byTier = evidenceKind(a).index.compareTo(evidenceKind(b).index);
        if (byTier != 0) {
          return byTier;
        }
        final byScore = relevance(b).compareTo(relevance(a));
        return byScore != 0 ? byScore : a.key.compareTo(b.key);
      });

    for (final candidate in ranked) {
      final kind = evidenceKind(candidate);
      final document = _documents[candidate.key]!;
      final isDuplicate = document.terms.length >= 4 &&
          picks.any(
            (pick) =>
                TextAnalysisUtils.jaccardSimilarity(
                  document.terms,
                  _documents[pick.id]!.terms,
                ) >=
                0.88,
          );
      if (isDuplicate) {
        continue;
      }
      picks.add(
        (
          id: candidate.key,
          kind: kind,
          evidence: switch (kind) {
            RelatedNoteEvidence.text => _textEvidence(document, query),
            RelatedNoteEvidence.source => sameSources[candidate.key]!,
            _ => candidate.value.tag!,
          },
        ),
      );
      if (picks.length == limit || kind == RelatedNoteEvidence.tag) {
        break;
      }
    }
    return picks;
  }

  List<WalkConnection> related(
    String id, {
    required Set<String> shown,
    required Set<String> excluded,
    int limit = 4,
  }) {
    final source = _documents[id];
    if (source == null || limit <= 0) {
      return [];
    }
    final scores = <String, _WalkScore>{};
    final links = _linksById[id] ?? const <String, WalkRelation>{};
    final references = <WalkConnection>[];
    for (final entry in links.entries) {
      if (!excluded.contains(entry.key)) {
        references.add((id, entry.key, entry.value, ''));
      }
    }
    // 显式关系可以回连到已有节点。探索名额优先留给还没看到的笔记。
    references.sort((a, b) {
      final order = (shown.contains(a.$2) ? 1 : 0)
          .compareTo(shown.contains(b.$2) ? 1 : 0);
      return order != 0 ? order : a.$2.compareTo(b.$2);
    });
    final picks =
        references.where((ref) => !shown.contains(ref.$2)).take(limit).toList();
    if (picks.length < limit) {
      _scoreTags(source, shown, excluded, scores);
      final query = _scoreText(source, shown, excluded, scores);
      final textMatches = <MapEntry<String, _WalkScore>>[];
      final tagMatches = <MapEntry<String, _WalkScore>>[];
      for (final entry in scores.entries) {
        if (links.containsKey(entry.key)) {
          continue;
        }
        if (entry.value.hasTextMatch) {
          textMatches.add(entry);
        } else if (entry.value.tag != null) {
          tagMatches.add(entry);
        }
      }
      while (picks.length < limit &&
          (textMatches.isNotEmpty || tagMatches.isNotEmpty)) {
        final candidates = textMatches.isNotEmpty ? textMatches : tagMatches;
        var bestIndex = 0;
        var bestScore = -1.0;
        for (var i = 0; i < candidates.length; i++) {
          final value = _branchScore(candidates[i], picks);
          if (value > bestScore) {
            bestIndex = i;
            bestScore = value;
          }
        }
        final best = candidates.removeAt(bestIndex);
        final score = best.value;
        picks.add(
          (
            id,
            best.key,
            score.hasTextMatch ? WalkRelation.text : WalkRelation.tag,
            score.hasTextMatch
                ? _textEvidence(_documents[best.key]!, query)
                : score.tag!,
          ),
        );
        // 只留一个纯标签候选，让短笔记也有机会连上主题。
        if (!score.hasTextMatch) {
          break;
        }
      }
    }
    // 只补少量真实的跨分支连线，长路径仍然容易读。
    return [
      ...picks,
      ...references.where((ref) => shown.contains(ref.$2)).take(2),
    ];
  }

  void _scoreTags(
    _WalkDocument source,
    Set<String> shown,
    Set<String> excluded,
    Map<String, _WalkScore> scores, {
    bool relatedNotes = false,
  }) {
    for (final tag in source.tags) {
      if (tag == WeReadNoteBuilder.sourceTag) {
        continue;
      }
      final postings = _tags[tag]!;
      final maxFrequency = max(relatedNotes ? 2 : 3, _documents.length * 0.35);
      if (postings.length > maxFrequency ||
          (relatedNotes && postings.length == _documents.length)) {
        continue;
      }
      final weight = _idf(postings.length);
      for (final id in postings) {
        if (id == source.note.id ||
            shown.contains(id) ||
            excluded.contains(id)) {
          continue;
        }
        final score = scores.putIfAbsent(id, _WalkScore.new);
        score.tagScore += weight;
        if (weight > score.bestTagWeight) {
          score
            ..tag = tag
            ..bestTagWeight = weight;
        }
      }
    }
  }

  List<String> _scoreText(
    _WalkDocument source,
    Set<String> shown,
    Set<String> excluded,
    Map<String, _WalkScore> scores,
  ) {
    final query = source.terms.where((term) {
      final count = _terms[term]!.length;
      return count > 1 && count <= max(3, _documents.length * 0.25);
    }).toList()
      ..sort((a, b) {
        final frequency = _terms[a]!.length.compareTo(_terms[b]!.length);
        return frequency != 0 ? frequency : b.length.compareTo(a.length);
      });
    final searchTerms = query.take(24).toList();
    const k1 = 1.2;
    const b = 0.75;
    for (final term in searchTerms) {
      final postings = _terms[term]!;
      final weight = _idf(postings.length);
      for (final entry in postings.entries) {
        final id = entry.key;
        if (id == source.note.id ||
            shown.contains(id) ||
            excluded.contains(id)) {
          continue;
        }
        final length = _documents[id]!.length;
        final frequency = entry.value;
        final bm25 = weight *
            frequency *
            (k1 + 1) /
            (frequency + k1 * (1 - b + b * length / _averageLength));
        final score = scores.putIfAbsent(id, _WalkScore.new);
        score.textScore += bm25;
        score.termCount++;
      }
    }
    return searchTerms;
  }

  String _textEvidence(_WalkDocument document, List<String> query) {
    // 只为入选笔记查找原文，同一个词项的重复出现不提高句段优先级。
    final patterns = [
      for (final term in query.where(document.terms.contains))
        RegExp(
          _chineseTerm.hasMatch(term)
              ? RegExp.escape(term)
              : '(?<![\\p{L}\\p{N}])${RegExp.escape(term)}(?![\\p{L}\\p{N}])',
          caseSensitive: false,
          unicode: true,
        ),
    ];
    var bestCount = 0;
    var evidence = '';
    for (final raw in document.body.split(_clauseBoundary)) {
      final clause = raw.replaceAll(_spaces, ' ').trim();
      RegExpMatch? anchor;
      var count = 0;
      for (final pattern in patterns) {
        final match = pattern.firstMatch(clause);
        if (match != null) {
          anchor ??= match;
          count++;
        }
      }
      if (anchor != null && count > bestCount) {
        bestCount = count;
        evidence = _excerptAround(clause, anchor);
      }
    }
    return evidence;
  }

  String _excerptAround(String clause, RegExpMatch anchor) {
    final matchLength = anchor.group(0)!.runes.length;
    final limit = max(36, matchLength);
    final characters = clause.runes.toList();
    if (characters.length <= limit) {
      return clause;
    }

    final matchStart = clause.substring(0, anchor.start).runes.length;
    final matchEnd = matchStart + matchLength;
    final contextBefore = (limit - matchLength) ~/ 2;
    var start =
        (matchStart - contextBefore).clamp(0, characters.length - limit);
    var end = start + limit;
    bool cutsWord(int at) =>
        _wordCharacter.hasMatch(String.fromCharCode(characters[at - 1])) &&
        _wordCharacter.hasMatch(String.fromCharCode(characters[at]));
    while (start > 0 && start < matchStart && cutsWord(start)) {
      start++;
    }
    while (end < characters.length && end > matchEnd && cutsWord(end)) {
      end--;
    }
    final excerpt = String.fromCharCodes(characters, start, end).trim();
    return '${start > 0 ? '…' : ''}$excerpt${end < characters.length ? '…' : ''}';
  }

  double _branchScore(
    MapEntry<String, _WalkScore> entry,
    List<WalkConnection> picks,
  ) {
    final score = entry.value;
    final document = _documents[entry.key]!;
    var redundancy = 0.0;
    for (final pick in picks) {
      final other = _documents[pick.$2]!;
      final similarity =
          TextAnalysisUtils.jaccardSimilarity(document.terms, other.terms);
      final sameTag = score.tag != null && other.tags.contains(score.tag);
      final sameSource = document.isWeRead && other.isWeRead;
      redundancy = max(
        redundancy,
        similarity * 0.65 + (sameTag ? 0.15 : 0) + (sameSource ? 0.12 : 0),
      );
    }
    // 少量标签加分用于区分正文相近的候选，避免多个标签压过强正文。
    final relevance = score.hasTextMatch
        ? log(1 + score.textScore) + min(0.35, score.tagScore * 0.1)
        : score.tagScore;
    return relevance * (1 - redundancy);
  }
}

class _WalkDocument {
  const _WalkDocument({
    required this.note,
    required this.tags,
    required this.terms,
    required this.body,
    required this.length,
    required this.isWeRead,
  });

  final WalkNote note;
  final Set<String> tags;
  final Set<String> terms;
  final String body;
  final int length;
  final bool isWeRead;
}

class _WalkScore {
  double tagScore = 0;
  double bestTagWeight = 0;
  double textScore = 0;
  int termCount = 0;
  String? tag;

  bool get hasTextMatch => termCount >= 2 && textScore >= 0.5;
}
