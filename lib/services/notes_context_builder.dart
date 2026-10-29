import 'package:inkpaper/models/note_model.dart';
import 'package:intl/intl.dart';

/// 打包好的笔记上下文。
class NotesContext {
  const NotesContext({
    required this.text,
    required this.noteCount,
    required this.totalCandidates,
    required this.characters,
    required this.truncated,
  });

  /// 拼给模型的文本。
  final String text;

  /// 实际纳入的条数。
  final int noteCount;

  /// 有内容的笔记总数（用于告诉用户"共多少条，装了前多少条"）。
  final int totalCandidates;

  final int characters;

  /// 是否因为预算被截断。
  final bool truncated;
}

/// 把全库笔记压成一段可以塞进 prompt 的上下文。
///
/// 设计取舍：
/// - 只保留纯文字（图片 / 音频等 markdown 全部剔除），用户明确说不要图片；
/// - 按时间倒序优先装最近的笔记，装到字数预算为止；
/// - 单条截断，避免一条超长日记吃掉整个预算；
/// - 每行带日期和标签，方便模型引用来源。
class NotesContextBuilder {
  NotesContextBuilder._();

  /// 约 2 万 token 的正文预算：再大就会拖慢首字并抬高成本，
  /// 所以超出的部分用"只带了最近 N 条"的方式明确告知用户。
  static const int defaultMaxCharacters = 28000;
  static const int defaultMaxNotes = 200;

  /// 单条笔记最多保留的字符数。
  static const int perNoteLimit = 400;

  static NotesContext build(
    List<Note> notes, {
    int maxCharacters = defaultMaxCharacters,
    int maxNotes = defaultMaxNotes,
    int perNoteLimit = NotesContextBuilder.perNoteLimit,
  }) {
    final candidates = <_Entry>[];
    for (final note in notes) {
      final plain = stripMedia(note.content);
      if (plain.isEmpty) {
        continue;
      }
      candidates.add(_Entry(note.displayTime, note.tags, plain));
    }

    candidates.sort((a, b) => b.time.compareTo(a.time));

    final buffer = StringBuffer();
    var used = 0;
    var count = 0;
    for (final entry in candidates) {
      if (count >= maxNotes || used >= maxCharacters) {
        break;
      }
      final body = entry.text.length > perNoteLimit
          ? '${entry.text.substring(0, perNoteLimit)}…'
          : entry.text;
      final tags = entry.tags.isEmpty
          ? ''
          : ' ${entry.tags.take(4).map((tag) => '#$tag').join(' ')}';
      final line = '${count + 1}. [${_formatDate(entry.time)}]$tags\n$body\n';
      buffer.write(line);
      used += line.length;
      count++;
    }

    return NotesContext(
      text: buffer.toString().trim(),
      noteCount: count,
      totalCandidates: candidates.length,
      characters: used,
      truncated: count < candidates.length,
    );
  }

  /// 去掉图片、音频、附件这类非文字内容，只留下正文。
  static String stripMedia(String content) {
    var text = content;
    // ![alt](url)
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // [文字](file://… / content://… / blob:…) —— 附件链接没有阅读价值
    text = text.replaceAll(
      RegExp(r'\[[^\]]*\]\((?:file|content|blob):[^)]*\)'),
      ' ',
    );
    // 裸附件地址
    text = text.replaceAll(
      RegExp(r'(?:file|content)://\S+'),
      ' ',
    );
    // 分隔线 / 多余空行
    text = text.replaceAll(RegExp(r'^\s*[-*_]{3,}\s*$', multiLine: true), '');
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  static String _formatDate(DateTime time) {
    final now = DateTime.now();
    final pattern = time.year == now.year ? 'MM-dd' : 'yyyy-MM-dd';
    return DateFormat(pattern).format(time);
  }
}

class _Entry {
  _Entry(this.time, this.tags, this.text);

  final DateTime time;
  final List<String> tags;
  final String text;
}
