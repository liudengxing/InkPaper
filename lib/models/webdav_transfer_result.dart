/// 最近一次 WebDAV 备份/恢复的结果。
///
/// 供设置页常驻展示：之前结果只通过 SnackBar 弹一下，用户既来不及看清，
/// 也看不出「图片到底备份了多少」。这里把结果落盘，页面随时可回看。
class WebDavTransferResult {
  const WebDavTransferResult({
    required this.isBackup,
    required this.success,
    required this.finishedAt,
    this.notes = 0,
    this.resources = 0,
    this.resourcesSkipped = 0,
    this.resourcesUnavailable = 0,
    this.errors = 0,
    this.errorSamples = const [],
    this.message = '',
  });

  factory WebDavTransferResult.fromJson(Map<String, dynamic> json) {
    final time = json['finishedAt']?.toString();
    return WebDavTransferResult(
      isBackup: json['isBackup'] as bool? ?? true,
      success: json['success'] as bool? ?? false,
      finishedAt: time == null
          ? DateTime.now()
          : DateTime.tryParse(time) ?? DateTime.now(),
      notes: (json['notes'] as num?)?.toInt() ?? 0,
      resources: (json['resources'] as num?)?.toInt() ?? 0,
      resourcesSkipped: (json['resourcesSkipped'] as num?)?.toInt() ?? 0,
      resourcesUnavailable:
          (json['resourcesUnavailable'] as num?)?.toInt() ?? 0,
      errors: (json['errors'] as num?)?.toInt() ?? 0,
      errorSamples: (json['errorSamples'] as List?)
              ?.map((item) => item.toString())
              .toList() ??
          const [],
      message: json['message']?.toString() ?? '',
    );
  }

  /// true 表示备份，false 表示恢复。
  final bool isBackup;

  /// 本次操作是否成功。
  final bool success;

  /// 完成时间。
  final DateTime finishedAt;

  /// 涉及笔记数（备份=上传，恢复=已恢复）。
  final int notes;

  /// 涉及图片资源数（备份=本次新上传，恢复=落地的图片）。
  final int resources;

  /// 远端已存在、本次跳过的图片数（增量生效的直接体现）。
  final int resourcesSkipped;

  /// 本地没有副本、又没有可用服务器来源，本次没能备份的附件数。
  ///
  /// 与 [errors] 分开：这是「本来就没缓存过」，不是备份失败。
  final int resourcesUnavailable;

  /// 错误数；大于 0 时说明有部分内容没处理成功。
  final int errors;

  /// 前几条失败明细（资源路径 + 原因），用于直接定位问题。
  final List<String> errorSamples;

  /// 失败原因（成功时为空）。
  final String message;

  Map<String, dynamic> toJson() => {
        'isBackup': isBackup,
        'success': success,
        'finishedAt': finishedAt.toIso8601String(),
        'notes': notes,
        'resources': resources,
        'resourcesSkipped': resourcesSkipped,
        'resourcesUnavailable': resourcesUnavailable,
        'errors': errors,
        'errorSamples': errorSamples,
        'message': message,
      };
}
