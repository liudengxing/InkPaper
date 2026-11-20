import 'package:flutter/material.dart';

/// 洞察视角的图标标识。
///
/// 只存枚举名而不是 `IconData` 的 codePoint：自定义视角要写进
/// SharedPreferences，而 `IconData` 序列化后反查需要常量表，不如直接用枚举。
enum InsightLensIcon {
  pattern('pattern', Icons.blur_on_rounded),
  clarify('values', Icons.balance_rounded),
  inversion('inversion', Icons.swap_vert_rounded),
  secondOrder('second_order', Icons.layers_outlined),
  cbt('cbt', Icons.healing_outlined),
  persona('persona', Icons.fingerprint_rounded),
  custom('custom', Icons.auto_awesome_outlined);

  const InsightLensIcon(this.key, this.icon);

  final String key;
  final IconData icon;

  static InsightLensIcon fromKey(String? key) {
    for (final value in InsightLensIcon.values) {
      if (value.key == key) {
        return value;
      }
    }
    return InsightLensIcon.custom;
  }
}

/// 一个洞察视角 = 一段提示词 + 展示用的元数据。
///
/// 和 flomo 的形状一致：视角卡片只展示名称、描述、署名，真正的差异全在
/// [prompt] 里。内置视角的 [prompt] 允许用户改写（改写后 [edited] 为 true），
/// 自定义视角则整条都由用户填写。
class InsightLens {
  const InsightLens({
    required this.id,
    required this.name,
    required this.description,
    required this.prompt,
    required this.icon,
    this.author = 'InkPaper',
    this.builtIn = false,
    this.edited = false,
  });

  factory InsightLens.fromJson(Map<String, dynamic> json) => InsightLens(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '未命名视角',
        description: json['description']?.toString() ?? '',
        prompt: json['prompt']?.toString() ?? '',
        icon: InsightLensIcon.fromKey(json['icon']?.toString()),
        author: json['author']?.toString() ?? '我',
      );

  final String id;
  final String name;
  final String description;

  /// 视角专属提示词。统一规则由 `AiInsightService.systemPrompt` 追加，
  /// 这里只写「这个视角怎么分析」。
  final String prompt;

  final InsightLensIcon icon;

  /// 署名，内置视角是 InkPaper，自定义视角是「我」。
  final String author;

  final bool builtIn;

  /// 内置视角的提示词是否被用户改过。
  final bool edited;

  String get authorLabel => author.isEmpty ? 'InkPaper' : author;

  InsightLens copyWith({
    String? name,
    String? description,
    String? prompt,
    InsightLensIcon? icon,
    String? author,
    bool? builtIn,
    bool? edited,
  }) =>
      InsightLens(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        prompt: prompt ?? this.prompt,
        icon: icon ?? this.icon,
        author: author ?? this.author,
        builtIn: builtIn ?? this.builtIn,
        edited: edited ?? this.edited,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'prompt': prompt,
        'icon': icon.key,
        'author': author,
      };
}

/// 内置的六个视角。
///
/// 反推依据：flomo 官方帮助中心对每个视角的一句话定位、少楠在访谈里公开的
/// 「提示词里专门强调第一条笔记最重要」、以及公开截图里每个视角的输出结构。
/// 这不是官方原文，是按产品行为写的等价实现。
const List<InsightLens> builtInInsightLenses = [
  InsightLens(
    id: 'default',
    name: '深度挖掘',
    description: '挖掘笔记背后隐藏的思维模式与深层内在矛盾',
    icon: InsightLensIcon.pattern,
    builtIn: true,
    prompt: '''
视角：深层模式。

1. 通读全部笔记，找出 2-3 条反复出现的线索。注意不是标签，是行为模式：他反复在什么事情上花时间、反复被什么触发、反复回避什么。
2. 对每条线索，指出它内部的矛盾：他在同一件事上同时想要什么、又害怕什么。
3. 指出一个他没有直接写出来、但从记录方式本身能看出的东西。例如：只记录结果不记录过程、只在情绪低落时记录、大量笔记都在解释同一个已经做出的决定。
4. 最后给一句能推动他继续想下去的问题。不要给建议，不要收尾成鸡汤。''',
  ),
  InsightLens(
    id: 'values',
    name: '价值澄清',
    description: '从笔记里找出你真正看重的东西，从混乱回到核心',
    icon: InsightLensIcon.clarify,
    builtIn: true,
    prompt: '''
视角：价值排序。

1. 列出笔记里他反复投入时间、情绪或金钱的对象，每条注明依据。
2. 区分「他说自己看重什么」和「他实际的选择指向什么」。把两者不一致的地方单独指出来，这是这次分析的重点。
3. 归纳 3 条真实的价值观排序，每条至少给两条笔记支撑。
4. 指出一个他口头重视、但行为上一直排在最后的价值。
5. 给一个可检验的方法：未来两周出现什么情况，说明这个排序需要修正。''',
  ),
  InsightLens(
    id: 'inversion',
    name: '逆向思考',
    description: '通过芒格的逆向思维来考察笔记中的关键目标',
    icon: InsightLensIcon.inversion,
    builtIn: true,
    prompt: '''
视角：芒格式逆向思考。

1. 找出笔记里反复出现的 2-3 个关键目标，注明依据。
2. 对每个目标做反向提问：「如果我要确保这件事彻底失败，最可靠的做法是什么？」给出 3 条具体的失败路径。
3. 回到笔记，逐条检查他是不是正在做这些事。做了就直说并引用笔记；没做的也要说清楚，不要含糊。
4. 只给一条「反过来做」的调整，要具体到下周就能执行。

约束：避免愚蠢比追求聪明更可靠。不要给宏大战略，不要一次列五条建议。''',
  ),
  InsightLens(
    id: 'second_order',
    name: '二阶思考',
    description: '从笔记中识别出问题，并提炼出问题之上的问题',
    icon: InsightLensIcon.secondOrder,
    builtIn: true,
    prompt: '''
视角：二阶思考。

1. 列出他正在试图解决的 2-3 个具体问题，注明依据。
2. 对每个问题追问一层：这个问题成立的前提是什么？如果前提不成立，问题还成立吗？
3. 提炼「问题之上的问题」——那个让这些具体问题反复出现的更上层原因。只能给一个。
4. 判断：这些具体问题里，哪些该解决，哪些该接受，哪些其实是同一个问题的不同表现。
5. 只针对最上层的问题给一个动作，其余问题明确说「先不处理」。''',
  ),
  InsightLens(
    id: 'cbt',
    name: 'CBT 疗法',
    description: '识别笔记中的思维陷阱并提供具体的改善建议',
    icon: InsightLensIcon.cbt,
    builtIn: true,
    prompt: '''
视角：认知行为疗法的自查。

1. 找出笔记里符合这些模式的表达：全有或全无、灾难化、读心术（断定别人怎么想）、应该式（我必须／他应该）、以偏概全、情绪化推理（我感觉糟糕所以事情很糟）。
2. 每一条按三段写：原文依据[序号] → 这是哪种模式 → 证据缺口在哪里（他跳过了什么事实）。
3. 给一个替代解释：不是安慰，而是同样符合事实、但更准确的一种说法。
4. 给一个行为实验：下周可以做的一件小事，用来验证这个替代解释。

结尾用一句话说明：这是自查框架，不是治疗，也不构成诊断。''',
  ),
  InsightLens(
    id: 'mbti',
    name: 'MBTI 分析',
    description: '从你的笔记内容中解读真实的 MBTI 人格类型',
    icon: InsightLensIcon.persona,
    builtIn: true,
    prompt: '''
视角：MBTI 倾向解读。

1. 分别看四个维度：E/I 能量来源、S/N 信息获取、T/F 决策依据、J/P 生活取向。
2. 每个维度给出倾向判断，附至少两条笔记依据，并说明有没有反例。
3. 给出最可能的四字母类型，并标注置信度（高／中／低）与理由。
4. 指出笔记里与这个类型明显不符的部分，并说明更可能是情境差异还是正在变化。
5. 结尾说明局限：笔记是经过自我筛选的表达，不等于完整人格，这个结果不能当作测评结论。''',
  ),
];
