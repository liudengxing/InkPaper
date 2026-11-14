/// 集中管理的翻译数据类（仅支持中英文）
/// 使用映射结构存储所有翻译文本
class Translations {
  // 私有构造函数，防止实例化
  Translations._();

  /// 所有翻译数据的映射表
  /// 格式: {'key': {'zh': '中文', 'en': 'English'}}
  static final Map<String, Map<String, String>> _translations = {
    // ===== 基础UI =====
    'home': {'zh': '首页', 'en': 'Home'},
    'notes': {'zh': '笔记', 'en': 'Notes'},
    'tags': {'zh': '标签', 'en': 'Tags'},
    'delete': {'zh': '删除', 'en': 'Delete'},
    'confirm': {'zh': '确认', 'en': 'Confirm'},
    'save': {'zh': '保存', 'en': 'Save'},

    // ===== 侧边栏 =====
    'allNotes': {'zh': '全部笔记', 'en': 'All Notes'},
    'randomReview': {'zh': '随机回顾', 'en': 'Random Review'},
    'imageGallery': {'zh': '有图片', 'en': 'With Images'},
    'allTags': {'zh': '全部标签', 'en': 'All Tags'},
    'account': {'zh': '账户', 'en': 'Account'},
    'dataSync': {'zh': '数据同步', 'en': 'Data Sync'},
    'notifications': {'zh': '通知', 'en': 'Notifications'},
    'help': {'zh': '帮助', 'en': 'Help'},
    'about': {'zh': '关于', 'en': 'About'},
    'logout': {'zh': '退出登录', 'en': 'Logout'},
    'dataCleanup': {'zh': '数据清理', 'en': 'Data Cleanup'},
    'laboratory': {'zh': '实验室', 'en': 'Laboratory'},
    'knowledgeGraph': {'zh': '知识图谱', 'en': 'Knowledge Graph'},
    'activityLog': {'zh': '活动记录', 'en': 'Activity Log'},
    'notificationCenter': {'zh': '通知中心', 'en': 'Notification Center'},
    'totalWords': {'zh': '总字数', 'en': 'Total Words'},
    'totalNotes': {'zh': '笔记数', 'en': 'Notes Count'},
    'totalDays': {'zh': '记录天数', 'en': 'Days Recorded'},
    'todayWords': {'zh': '今日字数', 'en': 'Today Words'},
    'todayNewNotes': {'zh': '新增笔记', 'en': 'New Notes'},
    'todayNewTags': {'zh': '新增标签', 'en': 'New Tags'},
    'functionMenu': {'zh': '功能菜单', 'en': 'Function Menu'},

    // ===== 笔记相关 =====
    'noteContent': {'zh': '笔记内容', 'en': 'Note Content'},
    'searchResultsCount': {
      'zh': '找到 {count} 条结果',
      'en': '{count} results',
    },
    'noSearchResults': {
      'zh': '没有找到相关笔记',
      'en': 'No matching notes',
    },

    // ===== 设置 =====
    'settings': {'zh': '设置', 'en': 'Settings'},
    'settingsAccountAndConnection': {
      'zh': '账户与连接',
      'en': 'Account & Connection',
    },
    'settingsGeneral': {'zh': '通用', 'en': 'General'},
    'settingsDataManagement': {'zh': '数据管理', 'en': 'Data Management'},
    'settingsSupport': {'zh': '支持', 'en': 'Support'},
    'accountInfo': {'zh': '账户信息', 'en': 'Account Info'},
    'preferences': {'zh': '偏好设置', 'en': 'Preferences'},
    'appearance': {'zh': '外观', 'en': 'Appearance'},
    'theme': {'zh': '主题', 'en': 'Theme'},
    'fontSize': {'zh': '字体大小', 'en': 'Font Size'},
    'selectFontSize': {'zh': '选择字体大小', 'en': 'Select Font Size'},
    'selectTheme': {'zh': '选择主题', 'en': 'Select Theme'},
    'selectFont': {'zh': '选择字体', 'en': 'Select Font'},
    'selectNoteVisibility': {'zh': '选择笔记状态', 'en': 'Select Note Status'},
    'language': {'zh': '语言', 'en': 'Language'},
    'sync': {'zh': '同步', 'en': 'Sync'},
    'privacy': {'zh': '隐私', 'en': 'Privacy'},
    'aiSettings': {'zh': 'AI设置', 'en': 'AI Settings'},
    'feedback': {'zh': '反馈', 'en': 'Feedback'},
    'lastSync': {'zh': '上次同步', 'en': 'Last Sync'},

    // ===== 时间 =====
    'today': {'zh': '今天', 'en': 'Today'},
    'success': {'zh': '成功', 'en': 'Success'},
    'failed': {'zh': '失败', 'en': 'Failed'},

    // ===== 删除确认 =====

    // ===== 登录注册 =====
    'login': {'zh': '登录', 'en': 'Login'},
    'register': {'zh': '注册', 'en': 'Register'},
    'username': {'zh': '用户名', 'en': 'Username'},
    'password': {'zh': '密码', 'en': 'Password'},
    'email': {'zh': '邮箱', 'en': 'Email'},
    'serverUrl': {'zh': '服务器地址', 'en': 'Server URL'},
    'logoutButton': {'zh': '退出登录', 'en': 'Logout'},
    'localMode': {'zh': '本地运行', 'en': 'Local Mode'},
    'logoutConfirm': {'zh': '确认退出', 'en': 'Confirm Logout'},
    'logoutMessage': {'zh': '确定要退出登录吗？', 'en': 'Are you sure to logout?'},
    'confirmLogout': {'zh': '确认退出', 'en': 'Confirm'},
    'logoutFailed': {'zh': '退出失败', 'en': 'Logout Failed'},

    // ===== 语言名称 =====
    'languageSystem': {'zh': '跟随系统', 'en': 'Follow System'},
    'languageChineseSimplified': {'zh': '简体中文', 'en': 'Simplified Chinese'},
    'languageEnglish': {'zh': '英语', 'en': 'English'},
    'connectionStatus': {'zh': '连接状态', 'en': 'Connection Status'},
    'diagnosing': {'zh': '诊断中...', 'en': 'Diagnosing...'},
    'connectionDiagnosis': {'zh': '连接诊断', 'en': 'Connection Diagnosis'},

    // ===== 账户信息 =====
    'nickname': {'zh': '昵称', 'en': 'Nickname'},
    'newPassword': {'zh': '新密码', 'en': 'New Password'},

    // ===== 导入导出 =====
    'lastBackup': {'zh': '最后备份', 'en': 'Last Backup'},
    'exportFormat': {'zh': '导出格式', 'en': 'Export Format'},
    'includeImages': {'zh': '包含图片', 'en': 'Include Images'},
    'export': {'zh': '导出', 'en': 'Export'},
    'import': {'zh': '导入', 'en': 'Import'},

    // ===== 实验室 =====
    'inDevelopment': {'zh': '开发中', 'en': 'In Development'},

    // ===== 反馈 =====

    // ===== 其他通知 =====
    'updatingFailed': {'zh': '更新失败', 'en': 'Update Failed'},
    'cannotOpenLink': {'zh': '无法打开链接', 'en': 'Cannot Open Link'},
    'copiedToClipboard': {'zh': '已复制到剪贴板', 'en': 'Copied to Clipboard'},
    'noteRestored': {'zh': '笔记已恢复', 'en': 'Note Restored'},
    'undo': {'zh': '撤销', 'en': 'Undo'},
    'showAll': {'zh': '显示全部', 'en': 'Show All'},
    'graphShowIsolated': {'zh': '显示孤立点', 'en': 'Show isolated'},
    'graphHideIsolated': {'zh': '隐藏孤立点', 'en': 'Hide isolated'},
    'graphBuilding': {'zh': '正在整理图谱', 'en': 'Building graph'},
    'graphOpenNote': {'zh': '打开笔记', 'en': 'Open note'},
    'graphFocusNode': {'zh': '聚焦关联', 'en': 'Focus links'},
    'graphClearSelection': {'zh': '清除选择', 'en': 'Clear selection'},
    'graphNoConnections': {'zh': '还没有引用关系', 'en': 'No linked notes yet'},
    'graphResetView': {'zh': '适配视图', 'en': 'Fit view'},

    // ===== AI设置 =====
    'aiFeatures': {'zh': 'AI功能', 'en': 'AI Features'},
    'apiConfiguration': {'zh': 'API配置', 'en': 'API Configuration'},
    'aiModel': {'zh': 'AI模型', 'en': 'AI Model'},
    'modelSelection': {'zh': '模型名称', 'en': 'Model Name'},
    'selectModel': {'zh': '常用模型示例', 'en': 'Common Model Examples'},
    'apiKey': {'zh': 'API密钥', 'en': 'API Key'},
    'saveConfiguration': {'zh': 'AI配置已保存', 'en': 'AI Config Saved'},

    // ===== 关于和帮助 =====
    'aboutUs': {'zh': '关于 InkPaper', 'en': 'About InkPaper'},
    'version': {'zh': '版本', 'en': 'Version'},
    'helpCenter': {'zh': '帮助中心', 'en': 'Help Center'},
    'gettingStarted': {'zh': '开始使用', 'en': 'Getting Started'},
    'noteFeatures': {'zh': '笔记功能', 'en': 'Note Features'},
    'tagFeatures': {'zh': '标签功能', 'en': 'Tag Features'},
    'formatEditing': {'zh': '格式编辑', 'en': 'Formatting'},
    'commonQuestions': {'zh': '常见问题', 'en': 'Common Questions'},

    // ===== 标签相关 =====
    'searchTags': {'zh': '搜索标签...', 'en': 'Search tags...'},

    // ===== 数据清理 =====
    'cleanupConfirm': {'zh': '确认清理', 'en': 'Confirm Cleanup'},
    'cleanupAllDataMessage': {
      'zh': '此操作将删除所有笔记数据。是否继续？',
      'en': 'This will delete all note data. Continue?',
    },
    'cleanupImagesMessage': {
      'zh': '此操作将删除所有未使用的图片文件。是否继续？',
      'en': 'This will delete all unused images. Continue?',
    },
    'cleanupHistoryMessage': {
      'zh': '此操作将删除所有导入导出历史记录。是否继续？',
      'en': 'This will delete all import/export history. Continue?',
    },
    'cleanupFailed': {'zh': '清理失败', 'en': 'Cleanup Failed'},
    'deleteAllHistorySubtitle': {
      'zh': '删除所有导入导出的历史记录',
      'en': 'Delete all import/export history',
    },
    'dangerOperationSubtitle': {
      'zh': '危险操作：删除所有本地笔记数据，此操作不可恢复',
      'en': 'Danger: Delete all local note data, cannot be undone',
    },
    'notesItem': {'zh': '条笔记', 'en': 'notes'},
    'imagesItem': {'zh': '张图片', 'en': 'images'},
    'notesCount': {'zh': '笔记数量', 'en': 'Notes Count'},
    'databaseSize': {'zh': '数据库大小', 'en': 'Database Size'},
    'cacheSize': {'zh': '缓存大小', 'en': 'Cache Size'},
    'imagesCount': {'zh': '图片数量', 'en': 'Images Count'},
    'refreshData': {'zh': '刷新数据', 'en': 'Refresh Data'},
    'allNotesCleanedSuccess': {'zh': '所有笔记已清理', 'en': 'All Notes Cleaned'},

    // ===== 主页空状态 =====
    'noNotesYet': {'zh': '还没有笔记', 'en': 'No notes yet'},
    'clickToCreate': {
      'zh': '点击右下角的按钮开始创建',
      'en': 'Click the button below to start creating',
    },

    // ===== 引导页 =====
    'onboardingTitle1': {'zh': '随手记录', 'en': 'Capture Notes'},
    'onboardingDesc1': {
      'zh': '打开就写，文字、图片、待办和链接都能放在一条笔记里',
      'en': 'Open and write. Keep text, images, todos, and links in one note.',
    },
    'onboardingTitle2': {'zh': '用标签整理', 'en': 'Organize with Tags'},
    'onboardingDesc2': {
      'zh': '支持层级标签、搜索和回顾，记录多了也能找回来',
      'en': 'Use nested tags, search, and review to find notes later.',
    },
    'onboardingTitle3': {'zh': '随时随地同步', 'en': 'Sync Anytime, Anywhere'},
    'onboardingDesc3': {
      'zh': '连接你自己的 Memos 服务，多端同步由你掌控',
      'en':
          'Connect your own Memos server and sync across devices on your terms.',
    },
    'onboardingTitle4': {'zh': '多平台支持', 'en': 'Multi-Platform Support'},
    'onboardingDesc4': {
      'zh': '支持手机、平板、电脑多端协作\n让你的创作思路在任何设备上延续',
      'en':
          'Support for phone, tablet, and computer collaboration\nContinue your creative flow on any device',
    },
    'skip': {'zh': '跳过', 'en': 'Skip'},
    'next': {'zh': '下一步', 'en': 'Next'},

    // ===== 其他设置 =====
    'fontSelection': {'zh': '字体选择', 'en': 'Font Selection'},
    'noteVisibility': {'zh': '默认笔记状态', 'en': 'Default Note Visibility'},
    'private': {'zh': '私密', 'en': 'Private'},
    'public': {'zh': '公开', 'en': 'Public'},
    'privateDesc': {'zh': '仅自己可见', 'en': 'Visible only to you'},
    'publicDesc': {'zh': '所有人可见', 'en': 'Visible to everyone'},
    'fontFamilyDefaultDesc': {
      'zh': '系统默认，清晰现代',
      'en': 'System default, clear and modern',
    },
    'fontFamilyNotoSans': {'zh': '思源黑体', 'en': 'Noto Sans SC'},
    'fontFamilyNotoSansDesc': {
      'zh': 'Noto Sans SC，现代简洁',
      'en': 'Noto Sans SC, modern and clean',
    },
    'fontFamilyNotoSerif': {'zh': '思源宋体', 'en': 'Noto Serif SC'},
    'fontFamilyNotoSerifDesc': {
      'zh': 'Noto Serif SC，优雅复古',
      'en': 'Noto Serif SC, elegant and classic',
    },
    'fontFamilyMaShanZheng': {'zh': '楷体风格', 'en': 'Kai Style'},
    'fontFamilyMaShanZhengDesc': {
      'zh': 'Ma Shan Zheng，手写风格',
      'en': 'Ma Shan Zheng, handwriting style',
    },
    'fontFamilyZcoolXiaowei': {'zh': '站酷小薇', 'en': 'Zcool XiaoWei'},
    'fontFamilyZcoolXiaoweiDesc': {
      'zh': 'Zcool XiaoWei，圆润可爱',
      'en': 'Zcool XiaoWei, rounded and cute',
    },
    'fontFamilyZcoolQingke': {'zh': '站酷庆科', 'en': 'Zcool QingKe'},
    'fontFamilyZcoolQingkeDesc': {
      'zh': 'Zcool QingKe HuangYou，活泼俏皮',
      'en': 'Zcool QingKe, lively and playful',
    },

    // ===== Markdown相关 =====

    // ===== 活跃度 =====
    'activityLevel': {'zh': '活跃度', 'en': 'Activity'},
    'unreadNotificationsCount': {
      'zh': '{count}条未读信息',
      'en': '{count} unread messages',
    },

    // ===== 通用对话框 =====
    'featureInDevelopment': {
      'zh': '该功能正在开发中，敬请期待！\n我们会尽快为您带来更多精彩功能。',
      'en':
          'This feature is under development, stay tuned!\nWe will bring you more exciting features soon.',
    },
    'ok': {'zh': '好的', 'en': 'OK'},

    // ===== 账户信息页面 =====
    'createdTimeLabel': {'zh': '创建时间：', 'en': 'Created: '},
    'emailNotSet': {'zh': '未设置邮箱', 'en': 'Email not set'},
    'basicInfo': {'zh': '基本信息', 'en': 'Basic Info'},
    'modifyPassword': {'zh': '修改密码', 'en': 'Change Password'},
    'syncPersonalInfo': {'zh': '立即同步', 'en': 'Sync Personal Info Now'},
    'syncPersonalInfoDesc': {
      'zh': '从服务器同步最新的个人资料',
      'en': 'Sync latest profile from server',
    },
    'logoutDesc': {
      'zh': '退出当前账号并返回登录页',
      'en': 'Logout and return to login page',
    },
    'welcomeToInkPaperShort': {
      'zh': '欢迎使用 InkPaper',
      'en': 'Welcome to InkPaper',
    },
    'loginToUnlockFeatures': {
      'zh': '登录后解锁更多精彩功能',
      'en': 'Login to unlock more features',
    },
    'cloudSyncFeature': {'zh': '云端同步', 'en': 'Cloud Sync'},
    'cloudSyncDesc': {
      'zh': '笔记实时同步，随时随地访问',
      'en': 'Real-time sync, access anywhere',
    },
    'aiAssistantFeature': {'zh': 'AI 助手', 'en': 'AI Assistant'},
    'aiAssistantDesc': {
      'zh': '智能总结、扩展、改进笔记内容',
      'en': 'Smart summarize, expand, and improve notes',
    },
    'remindersFeature': {'zh': '定时提醒', 'en': 'Reminders'},
    'remindersDesc': {
      'zh': '重要事项不错过，高效管理时间',
      'en': 'Never miss important tasks',
    },
    'connectionNormal': {
      'zh': '服务器连接正常，数据同步正常',
      'en': 'Server connection is normal',
    },
    'pleaseCheckServerSettings': {
      'zh': '请检查服务器设置',
      'en': 'Please check server settings',
    },
    'host': {'zh': '主机地址', 'en': 'Host'},
    'port': {'zh': '端口', 'en': 'Port'},
    'latency': {'zh': '延迟', 'en': 'Latency'},
    'lastSyncTime': {'zh': '上次同步', 'en': 'Last Sync'},
    'syncNowButton': {'zh': '立即同步', 'en': 'Sync Now'},
    'syncing': {'zh': '同步中...', 'en': 'Syncing...'},
    'portNumber': {'zh': '端口号', 'en': 'Port Number'},
    'enterAPIKey': {'zh': '请输入API密钥', 'en': 'Enter API key'},

    // ===== 意见反馈页面 =====
    'yourOpinionMatters': {'zh': '您的意见很重要', 'en': 'Your Opinion Matters'},
    'quickFeedback': {'zh': '快速反馈', 'en': 'Quick Feedback'},
    'uiBeautiful': {
      'zh': '界面很漂亮，体验很棒！',
      'en': 'Beautiful UI, great experience!',
    },
    'moreTemplates': {
      'zh': '希望增加更多笔记模板',
      'en': 'Hope to add more note templates',
    },
    'fasterSync': {'zh': '同步速度可以更快一些', 'en': 'Sync speed can be faster'},
    'moreFormats': {
      'zh': '希望支持更多文件格式',
      'en': 'Hope to support more file formats',
    },
    'featureSuggestion': {'zh': '功能建议', 'en': 'Feature Suggestion'},
    'problemReport': {'zh': '问题反馈', 'en': 'Problem Report'},
    'uiOptimization': {'zh': '界面优化', 'en': 'UI Optimization'},
    'performanceIssue': {'zh': '性能问题', 'en': 'Performance Issue'},
    'other': {'zh': '其他', 'en': 'Other'},
    'feedbackTypeRequired': {'zh': '反馈类型', 'en': 'Feedback Type'},
    'contactMethod': {'zh': '联系方式', 'en': 'Contact Method'},
    'feedbackContentRequired': {'zh': '反馈内容', 'en': 'Feedback Content'},
    'feedbackContentPlaceholder': {
      'zh': '请详细描述您遇到的问题或建议...\n\n我们会认真对待每一条反馈，并尽快回复您。',
      'en':
          'Please describe your issue or suggestion...\n\nWe take every feedback seriously and will respond soon.',
    },
    'sendFeedback': {'zh': '发送反馈', 'en': 'Send Feedback'},
    'copyEmail': {'zh': '复制邮箱', 'en': 'Copy Email'},
    'feedbackSuccess': {'zh': '反馈发送成功！', 'en': 'Feedback sent successfully!'},
    'feedbackSuccessMessage': {
      'zh': '感谢您的反馈！我们会认真阅读并尽快回复您。',
      'en':
          'Thank you for your feedback! We will read it carefully and reply soon.',
    },
    'feedbackFailed': {
      'zh': '发送失败，已为您复制反馈内容到剪贴板',
      'en': 'Send failed, feedback content copied to clipboard',
    },
    'feedbackCopied': {
      'zh': '反馈内容已复制到剪贴板\n您可以直接发送到：',
      'en': 'Feedback content copied to clipboard\nYou can send directly to: ',
    },

    // ===== 导入导出页面 =====
    'importExport': {'zh': '备份与同步', 'en': 'Backup & Sync'},
    'localBackupRestore': {'zh': '本地备份与恢复', 'en': 'Local Backup & Restore'},
    'localBackupDescription': {
      'zh': '备份数据到本地文件，或从本地文件恢复数据',
      'en': 'Backup data to local files or restore from local files',
    },
    'flomoImport': {'zh': 'Flomo 笔记导入', 'en': 'Flomo Note Import'},
    'flomoImportDescription': {
      'zh': '从 Flomo 导出的 HTML 文件导入笔记',
      'en': 'Import notes from Flomo exported HTML files',
    },
    'backupTip': {
      'zh': '💡 提示：建议定期备份数据，以防数据丢失。导入数据前请仔细检查文件格式。',
      'en':
          '💡 Tip: Regular backups recommended. Please verify file format before importing.',
    },
    'browserExtension': {'zh': 'Memos 浏览器插件', 'en': 'Memos Browser Extension'},
    'browserExtensionDescription': {
      'zh': '社区开发的浏览器扩展，支持 Chrome/Edge，可快速保存网页内容到 Memos',
      'en':
          'Community-developed browser extension for Chrome/Edge to save web content to Memos',
    },
    'exportTab': {'zh': '导出备份', 'en': 'Export'},
    'importTab': {'zh': '导入历史', 'en': 'Import'},
    'backupInfoTitle': {'zh': '备份信息', 'en': 'Backup Info'},
    'lastBackupTime': {'zh': '上次备份', 'en': 'Last Backup'},
    'neverBackedUp': {'zh': '从未备份', 'en': 'Never Backed Up'},
    'backupSizeLabel': {'zh': '备份大小', 'en': 'Backup Size'},
    'exportOptionsTitle': {'zh': '导出选项', 'en': 'Export Options'},
    'exportFormatLabel': {'zh': '导出格式', 'en': 'Export Format'},
    'includeImagesLabel': {'zh': '包含图片', 'en': 'Include Images'},
    'includeImagesDescription': {
      'zh': '所有格式都会打包为 ZIP，图片文件一并放进去',
      'en': 'All formats are packed as ZIP with images included',
    },
    'includeTagsLabel': {'zh': '包含标签', 'en': 'Include Tags'},
    'includeTagsDescription': {'zh': '保留笔记的标签信息', 'en': 'Keep tag information'},
    'encryptionOptionsTitle': {'zh': '加密选项', 'en': 'Encryption Options'},
    'encryptBackupLabel': {'zh': '加密备份', 'en': 'Encrypt Backup'},
    'encryptBackupDescription': {
      'zh': '使用密码加密您的备份文件',
      'en': 'Encrypt your backup with password',
    },
    'startExportButton': {'zh': '导出备份', 'en': 'Export Backup'},

    // ===== AI设置页面 =====
    'enableAIAssistant': {'zh': '启用AI助手', 'en': 'Enable AI Assistant'},
    'aiAssistantDescription': {
      'zh': '开启后可使用AI辅助功能',
      'en': 'Enable AI-powered features',
    },
    'apiAddressLabel': {'zh': 'API地址', 'en': 'API Address'},
    'apiKeyLabel': {'zh': 'API密钥', 'en': 'API Key'},

    // ===== 随机回顾页面 =====
    'randomReviewTitle': {'zh': '随机回顾', 'en': 'Random Review'},
    'noNotesToReview': {'zh': '没有可回顾的笔记', 'en': 'No notes to review'},
    'reviewSettings': {'zh': '回顾设置', 'en': 'Review Settings'},
    'reviewTimeRange': {'zh': '回顾时间范围：', 'en': 'Review Time Range:'},
    'reviewNotesCount': {'zh': '回顾笔记数量：', 'en': 'Number of Notes:'},
    'all': {'zh': '全部', 'en': 'All'},
    'days': {'zh': '天', 'en': 'days'},
    'items': {'zh': '条', 'en': ''},
    'lastEdited': {'zh': '最后编辑', 'en': 'Last Edited'},
    'itemsNote': {'zh': '条笔记', 'en': 'notes'},

    // ===== 反馈页面补充 =====
    'feedbackTitle': {'zh': '意见反馈', 'en': 'Feedback'},
    'feedbackWelcome': {
      'zh': '我们致力于为您提供最好的体验。您的每一个建议和反馈，都是我们前进的动力！',
      'en':
          'We are committed to providing you with the best experience. Every suggestion and feedback is our driving force!',
    },
    'enterEmailOrWechat': {
      'zh': '请输入您的邮箱或微信号（选填）',
      'en': 'Enter your email or WeChat (optional)',
    },
    'enterFeedbackContent': {'zh': '请输入您的反馈内容', 'en': 'Enter your feedback'},
    'sending': {'zh': '发送中...', 'en': 'Sending...'},
    'developerEmail': {'zh': '开发团队邮箱：', 'en': 'Developer Email: '},
    'feedbackResponseTime': {
      'zh': '我们会在 1-3 个工作日内回复您的反馈',
      'en': 'We will respond to your feedback within 1-3 business days',
    },
    'complete': {'zh': '完成', 'en': 'Complete'},

    // ===== 通用计量单位 =====
    'dayUnit': {'zh': '天', 'en': 'day(s)'},
    'noteUnit': {'zh': '条', 'en': ''},

    // ===== 导出导入补充 =====
    'importSuccess': {'zh': '导入成功', 'en': 'Import Success'},
    'importing': {'zh': '导入中...', 'en': 'Importing...'},
    'dataImported': {'zh': '数据已成功导入', 'en': 'Data imported successfully'},

    // ===== 服务器信息页面 =====
    'serverInfoReadOnlyNotice': {
      'zh': '此页面仅用于查看服务器连接状态和同步日志\n服务器设置请在登录页面配置',
      'en':
          'This page is for viewing server connection status and sync logs only\nPlease configure server settings on the login page',
    },
    'connectionInfoReadOnly': {
      'zh': '连接信息（只读）',
      'en': 'Connection Info (Read-only)',
    },
    'notConfigured': {
      'zh': '未配置',
      'en': 'Not Configured',
    },
    'enabled': {
      'zh': '已启用',
      'en': 'Enabled',
    },
    'disabled': {
      'zh': '未启用',
      'en': 'Disabled',
    },
    'modifyServerSettingsHint': {
      'zh': '要修改服务器设置，请退出登录后在登录页面配置',
      'en':
          'To modify server settings, please logout and configure on the login page',
    },
    'connectionLog': {
      'zh': '连接日志',
      'en': 'Connection Log',
    },
    'noLogRecords': {
      'zh': '暂无日志记录',
      'en': 'No log records',
    },

    // ===== 通知页面 =====
    'clear': {'zh': '清除', 'en': 'Clear'},
    'markAllRead': {'zh': '全部已读', 'en': 'Mark All Read'},
    'noNotifications': {'zh': '暂无通知', 'en': 'No notifications'},
    'earlier': {'zh': '更早', 'en': 'Earlier'},
    'notificationDeleted': {'zh': '已删除通知', 'en': 'Notification deleted'},
    'refreshNotificationsFailed': {
      'zh': '刷新通知失败，请检查网络连接',
      'en': 'Failed to refresh notifications, please check network',
    },
    'noReadNotificationsToDelete': {
      'zh': '没有已读通知可清除',
      'en': 'No read notifications to delete',
    },
    'clearReadNotifications': {
      'zh': '清除已读通知',
      'en': 'Clear Read Notifications',
    },
    'confirmClearReadNotifications': {
      'zh': '确定要清除 {count} 条已读通知吗？此操作不可恢复。',
      'en': 'Clear {count} read notifications? This cannot be undone.',
    },
    'notificationsCleared': {
      'zh': '已清除 {count} 条通知',
      'en': 'Cleared {count} notifications',
    },
    'clearFailed': {'zh': '清除失败', 'en': 'Clear failed'},
    'syncWarning': {
      'zh': '同步警告: 距离上次同步已超过{hours}小时',
      'en': 'Sync warning: {hours} hours since last sync',
    },
    'syncFailedMessage': {'zh': '同步失败', 'en': 'Sync failed'},
    'protocol': {'zh': '协议', 'en': 'Protocol'},
    'dnsResolutionSuccess': {
      'zh': 'DNS解析成功，耗时: {ms}ms',
      'en': 'DNS resolution successful, {ms}ms',
    },
    'testingAPIConnection': {
      'zh': '测试API连接...',
      'en': 'Testing API connection...',
    },
    'apiConnectionSuccess': {
      'zh': 'API连接成功，响应时间: {ms}ms',
      'en': 'API connection successful, {ms}ms',
    },

    // ===== 导入导出页面补充 =====
    'fileName': {'zh': '文件名', 'en': 'File name'},
    'shareBackupFile': {'zh': '分享备份文件', 'en': 'Share backup file'},
    'saveToDevice': {'zh': '保存到设备', 'en': 'Save to device'},
    'shareFailed': {'zh': '分享失败: 文件不存在', 'en': 'Share failed: File not found'},
    'selectExportMethod': {'zh': '选择导出方式', 'en': 'Select Export Method'},
    'selectHowToSaveExportedFile': {
      'zh': '请选择要如何保存导出的文件：',
      'en': 'Please select how to save the exported file:',
    },

    // ===== 时间分组 =====

    // ===== 帮助中心 =====
    'serverConnection': {'zh': '服务器连接', 'en': 'Server Connection'},

    // ===== 关于页面 =====
    'aboutInkPaper': {'zh': '关于InkPaper', 'en': 'About InkPaper'},
    'appTagline': {
      'zh': '记录是为了成为更好的自己',
      'en': 'Write to become a better you',
    },
    'appIntroduction': {
      'zh': 'InkPaper 是一款面向个人记录和知识整理的笔记应用。你可以本地使用，也可以连接自己部署的 Memos 服务同步笔记。',
      'en':
          'InkPaper is a note app for personal capture and knowledge organization. You can use it locally or sync with your own self-hosted Memos service.',
    },
    'appTechDescription': {
      'zh': '这些是当前版本已经开放的主要能力。不同 Memos 服务器版本的接口能力不同，应用会按服务器版本自动适配并尽量降级处理。',
      'en':
          'These are the main capabilities available in this version. Memos server APIs vary by version, so the app adapts to the detected server version and falls back where needed.',
    },
    'technicalDetails': {
      'zh':
          '当前只发布 Android 版本。应用提供富文本式编辑、Markdown 渲染、图片、标签、搜索、提醒、随机回顾、WebDAV 备份、导入导出和可选 AI 功能。',
      'en':
          'InkPaper ships for Android only. It includes rich-text-style editing, Markdown rendering, images, tags, search, reminders, random review, WebDAV backup, import/export, and optional AI features.',
    },
    'securityCommitment': {
      'zh': '笔记优先保存在本机。登录、同步、WebDAV 和 AI 相关配置由你主动设置；自部署服务中的数据由对应服务器保存和管理。',
      'en':
          'Notes are stored locally first. Login, sync, WebDAV, and AI settings are configured by you; data on self-hosted services is stored and managed by those servers.',
    },
    'coreFeaturesTitle': {'zh': '核心功能', 'en': 'Core Features'},
    'contactUs': {'zh': '联系我们', 'en': 'Contact Us'},
    'contactMessage': {
      'zh': '我们非常重视用户的反馈和建议。如果您有任何问题、意见或合作意向，请随时与我们联系。',
      'en':
          'We value your feedback and suggestions. If you have any questions, comments, or collaboration proposals, please feel free to contact us.',
    },
    'officialWebsite': {'zh': '官方网站', 'en': 'Official Website'},

    // ===== 功能标签 =====
    'memosExclusiveVersion': {
      'zh': 'Memos 多版本适配',
      'en': 'Memos Version Compatibility',
    },
    'markdownSupport': {'zh': 'Markdown支持', 'en': 'Markdown Support'},
    'intelligentTagSystem': {'zh': '层级标签', 'en': 'Nested Tags'},
    'fullTextSearch': {'zh': '全文搜索', 'en': 'Full-Text Search'},
    'randomReviewFeature': {'zh': '随机回顾', 'en': 'Random Review'},
    'dataStatistics': {'zh': '数据统计', 'en': 'Data Statistics'},
    'realtimeSync': {'zh': '实时同步', 'en': 'Real-time Sync'},
    'localEncryption': {'zh': '本地加密', 'en': 'Local Encryption'},
    'multiTheme': {'zh': '多主题切换', 'en': 'Multi-Theme'},
    'offlineUse': {'zh': '离线使用', 'en': 'Offline Use'},
    'dataExport': {'zh': '数据导出', 'en': 'Data Export'},
    'imageManagement': {'zh': '图片管理', 'en': 'Image Management'},
    'privateDeployment': {'zh': '私有化部署', 'en': 'Private Deployment'},

    // ===== P3 清理批次：补全直写中文的 UI 文案 =====
    'addTag': {'zh': '添加标签', 'en': 'Add tag'},
    'tagNameHint': {'zh': '输入标签名称...', 'en': 'Enter tag name...'},
    'expandOptions': {'zh': '展开选项', 'en': 'More options'},
    'notionTokenHint': {
      'zh': '输入 Notion Integration Token',
      'en': 'Enter Notion Integration Token',
    },
    'aiInsight': {'zh': 'AI洞察', 'en': 'AI Insight'},
    'zoomIn': {'zh': '放大', 'en': 'Zoom in'},
    'zoomOut': {'zh': '缩小', 'en': 'Zoom out'},
    'reviewWidgetRefreshTitle': {
      'zh': '随机回顾刷新',
      'en': 'Random Review Refresh',
    },
    'reviewWidgetRefreshSubtitle': {
      'zh': '控制随机回顾小组件多久换一条内容',
      'en': 'How often the random review widget shows a new note',
    },
    'reviewWidgetRangeTitle': {'zh': '随机回顾范围', 'en': 'Random Review Range'},
    'reviewWidgetRangeSubtitle': {
      'zh': '控制小组件优先从多久以前的笔记里抽取',
      'en': 'How far back the widget picks notes from',
    },
    'more': {'zh': '更多', 'en': 'More'},
    'refreshBatch': {'zh': '换一批', 'en': 'Shuffle'},
    'openSourceRepo': {'zh': '开源仓库', 'en': 'Source Repository'},
    'connectServer': {'zh': '接入服务器', 'en': 'Connect Server'},
    'enterBackupPassword': {'zh': '输入备份密码', 'en': 'Enter backup password'},
    'backupPassword': {'zh': '备份密码', 'en': 'Backup password'},
    'importFromLocalFile': {
      'zh': '从本地文件导入',
      'en': 'Import from local file',
    },
    'selectBackupFile': {
      'zh': '选择设备上的备份文件',
      'en': 'Pick a backup file on this device',
    },
    'syncFromCloud': {'zh': '从云端同步', 'en': 'Sync from cloud'},
    'syncWithCloudData': {'zh': '与云端数据同步', 'en': 'Sync with cloud data'},

    // ===== 导入导出页面补充 =====
    'importDescription': {'zh': '导入说明', 'en': 'Import Description'},
    'supportedFormatsDescription': {
      'zh': '支持导入以下格式的备份文件：',
      'en': 'Supported import formats:',
    },
    'markdownBatchImport': {
      'zh': '支持批量导入Markdown文件',
      'en': 'Batch import Markdown files supported',
    },
    'txtImportDescription': {
      'zh': '纯文本文件将作为单独笔记导入',
      'en': 'Text files will be imported as separate notes',
    },
    'jsonBackupDescription': {
      'zh': '标准备份格式，笔记 ID 与时间一并保留',
      'en': 'Standard backup, keeps note IDs and timestamps',
    },
    'zipBackupDescription': {
      'zh': '四种格式的导出都是 ZIP 包，正文和图片在一起',
      'en': 'All four formats export a ZIP with notes and images',
    },
    'importWarning': {
      'zh': '导入操作可能会影响现有数据，建议先备份当前数据',
      'en': 'Import may affect existing data, backup recommended',
    },
    'overwriteExistingNotes': {
      'zh': '覆盖现有笔记',
      'en': 'Overwrite Existing Notes',
    },
    'overwriteDescription': {
      'zh': '如果导入的笔记与现有笔记ID相同，则覆盖现有笔记',
      'en': 'Overwrite notes if IDs match',
    },
    'importAsNewNotes': {'zh': '作为新笔记导入', 'en': 'Import as New Notes'},
    'importAsNewDescription': {
      'zh': '所有导入的笔记将作为新笔记添加，不会影响现有笔记',
      'en': 'All imported notes will be added as new notes',
    },
    'importHistory': {'zh': '导入历史', 'en': 'Import History'},
    'refreshImportHistory': {'zh': '刷新导入历史', 'en': 'Refresh Import History'},
    'noImportHistory': {'zh': '暂无导入历史记录', 'en': 'No import history'},
    'setPassword': {'zh': '设置密码', 'en': 'Set Password'},
    'rememberPasswordWarning': {
      'zh': '请记住您的密码，如果忘记将无法恢复备份数据',
      'en': 'Remember your password, lost passwords cannot be recovered',
    },
    'exporting': {'zh': '导出中...', 'en': 'Exporting...'},

    // ===== 数据清理页面补充 =====
    'cleanCacheConfirm': {
      'zh': '此操作将清除应用缓存，可能会影响短期使用体验。是否继续？',
      'en':
          'This will clear app cache and may affect short-term user experience. Continue?',
    },
    'cacheCleanedSuccess': {'zh': '缓存已清理', 'en': 'Cache cleared'},
    'cleanCacheFailed': {'zh': '清理缓存失败', 'en': 'Failed to clear cache'},
    'imagesCleanedSuccess': {'zh': '图片已清理', 'en': 'Images cleared'},
    'cleanImagesFailed': {'zh': '清理图片失败', 'en': 'Failed to clear images'},
    'confirmReset': {'zh': '确认重置', 'en': 'Confirm Reset'},
    'resetSettingsConfirm': {
      'zh': '此操作将重置所有应用设置到默认状态，但不会删除笔记数据。是否继续？',
      'en':
          "This will reset all app settings to default, but won't delete notes. Continue?",
    },
    'settingsResetSuccess': {'zh': '应用设置已重置', 'en': 'App settings reset'},
    'resetSettingsFailed': {'zh': '重置设置失败', 'en': 'Failed to reset settings'},
    'historyCleanedSuccess': {
      'zh': '导入导出历史已清理',
      'en': 'Import/export history cleared',
    },
    'cleanHistoryFailed': {'zh': '清理历史失败', 'en': 'Failed to clear history'},
    'cleanupOperations': {'zh': '清理操作', 'en': 'Cleanup Operations'},
    'advancedOperations': {'zh': '高级操作', 'en': 'Advanced Operations'},
    'cleanCache': {'zh': '清除缓存', 'en': 'Clean Cache'},
    'cleanCacheDescription': {
      'zh': '删除临时文件和缓存，不会影响笔记数据',
      'en': 'Delete temporary files and cache, will not affect note data',
    },
    'cleanUnusedImages': {'zh': '清理未使用图片', 'en': 'Clean Unused Images'},
    'cleanUnusedImagesDescription': {
      'zh': '卸载被删除笔记引用的图片文件',
      'en': 'Remove images from deleted notes',
    },
    'cleanImportExportHistory': {
      'zh': '清理导入导出历史',
      'en': 'Clean Import/Export History',
    },
    'resetAppSettings': {'zh': '重置应用设置', 'en': 'Reset App Settings'},
    'deleteAllNotes': {'zh': '清理所有笔记', 'en': 'Delete All Notes'},

    // ===== 服务器信息页面 =====
    'notSynced': {'zh': '未同步', 'en': 'Not Synced'},
    'connected': {'zh': '已连接', 'en': 'Connected'},
    'connectionAbnormal': {'zh': '连接异常', 'en': 'Connection Abnormal'},
    'timeout': {'zh': '超时', 'en': 'Timeout'},
    'initializingServerConnection': {
      'zh': '初始化服务器连接页面...',
      'en': 'Initializing server connection page...',
    },
    'loggedInStatusDetected': {
      'zh': '检测到已登录状态',
      'en': 'Logged-in status detected',
    },
    'currentServer': {'zh': '当前服务器', 'en': 'Current server'},
    'usingProtocol': {'zh': '使用协议', 'en': 'Protocol'},
    'parseServerUrlFailed': {
      'zh': '解析服务器 URL 失败',
      'en': 'Failed to parse server URL',
    },

    // ===== 登录页面 =====
    'loginFailedCheckCredentials': {
      'zh': '登录失败，请检查账号密码和服务器地址',
      'en': 'Login failed, please check your credentials and server address',
    },
    'loginSuccessful': {'zh': '登录成功！', 'en': 'Login Successful!'},
    'welcomeBackPreparingSpace': {
      'zh': '欢迎回来！正在为您准备个人笔记空间...',
      'en': 'Welcome back! Preparing your personal note space...',
    },
    'intelligentNoteManagement': {
      'zh': '记录是为了成为更好的自己',
      'en': 'Write to become a better you',
    },
    'welcomeBack': {'zh': '欢迎回来', 'en': 'Welcome Back'},
    'continueCreativeJourney': {
      'zh': '继续您的创作之旅',
      'en': 'Continue your creative journey',
    },
    'createAccount': {'zh': '创建账户', 'en': 'Create Account'},
    'startYourCreativeJourney': {
      'zh': '开启您的创作之旅',
      'en': 'Start your creative journey',
    },
    'pleaseEnterUsername': {'zh': '请输入用户名', 'en': 'Please enter username'},
    'usernameNoSpaces': {
      'zh': '用户名不能包含空格',
      'en': 'Username cannot contain spaces',
    },
    'pleaseEnterPassword': {'zh': '请输入密码', 'en': 'Please enter password'},
    'passwordMinLength': {
      'zh': '密码至少需要6个字符',
      'en': 'Password must be at least 6 characters',
    },
    'server': {'zh': '服务器', 'en': 'Server'},
    'change': {'zh': '更改', 'en': 'Change'},
    'customize': {'zh': '自定义', 'en': 'Customize'},
    'saveAccountLocally': {
      'zh': '保存账号和密码到本地',
      'en': 'Save account and password locally',
    },
    'versionCompatibility': {
      'zh': '版本兼容性说明',
      'en': 'Version Compatibility Notes',
    },
    'serverAddress': {'zh': '服务器地址', 'en': 'Server Address'},
    'faq': {'zh': '常见问题', 'en': 'FAQ'},
    'answerYourQuestions': {'zh': '为您解答使用中的疑问', 'en': 'Answer your questions'},
    'whatIsServer': {'zh': '什么是服务器？', 'en': 'What is a server?'},
    'whatIsServerAnswer': {
      'zh': '服务器用于存储和同步您的笔记数据。请填写你自己部署的 Memos 服务器地址。',
      'en':
          'The server stores and syncs your notes. Enter the address of your own self-hosted Memos server.',
    },
    'howToSyncData': {'zh': '如何同步数据？', 'en': 'How to sync data?'},
    'howToSyncDataAnswer': {
      'zh': '登录后，您的笔记将自动同步到服务器。支持多端同步，在任何设备登录都能查看您的笔记。',
      'en':
          'After login, your notes will be automatically synced to the server. Multi-device sync is supported, you can view your notes on any device.',
    },

    // ===== 注册页面 =====
    'registrationSuccessful': {
      'zh': '注册成功！正在为您登录...',
      'en': 'Registration successful! Logging you in...',
    },
    'registrationFailed': {
      'zh': '注册失败，请检查信息后重试',
      'en': 'Registration failed, please check your information and try again',
    },
    'joinInkPaper': {'zh': '加入 InkPaper', 'en': 'Join InkPaper'},
    'startIntelligentNoteJourney': {
      'zh': '创建你的笔记空间',
      'en': 'Create your note space',
    },
    'startCreativeJourney': {
      'zh': '开启您的\n创作之旅',
      'en': 'Start Your\nCreative Journey',
    },
    'recordEachMoment': {
      'zh': '加入 InkPaper，记录每一个值得珍藏的时刻',
      'en': 'Join InkPaper, record every moment worth treasuring',
    },
    'usernameMinLength3': {
      'zh': '用户名至少需要3个字符',
      'en': 'Username must be at least 3 characters',
    },
    'usernameInvalidChars': {
      'zh': '用户名只能包含字母、数字、下划线和中文',
      'en':
          'Username can only contain letters, numbers, underscores and Chinese characters',
    },
    'passwordHint': {
      'zh': '至少8位，包含字母或数字',
      'en': 'At least 8 characters, containing letters or numbers',
    },
    'confirmPassword': {'zh': '确认密码', 'en': 'Confirm Password'},
    'pleaseConfirmPassword': {'zh': '请再次输入密码', 'en': 'Please confirm password'},
    'passwordMismatch': {'zh': '两次输入的密码不一致', 'en': 'Passwords do not match'},
    'autoLoginAfterRegistration': {
      'zh': '注册后自动登录',
      'en': 'Auto login after registration',
    },
    'betterExperience': {
      'zh': '为您提供更便捷的使用体验',
      'en': 'Provide you with a more convenient experience',
    },
    'startCreating': {'zh': '开始创作', 'en': 'Start Creating'},
    'alreadyHaveAccount': {
      'zh': '已有账号？立即登录',
      'en': 'Already have an account? Login now',
    },
    'howToRegister': {'zh': '如何注册账号？', 'en': 'How to register?'},
    'howToRegisterAnswer': {
      'zh': '填写用户名和密码（至少8位），勾选同意协议后点击"开始创作"即可注册。注册成功后将自动登录。',
      'en':
          'Fill in username and password (at least 8 characters), check the agreement box and click "Start Creating" to register. You will be automatically logged in after successful registration.',
    },
    'whatFeaturesSupported': {
      'zh': '笔记支持哪些功能？',
      'en': 'What features are supported?',
    },
    'whatFeaturesAnswer': {
      'zh': '支持富文本式编辑、Markdown 渲染、图片、标签、提醒、搜索、随机回顾、知识图谱和可选 AI 功能。',
      'en':
          'Supports rich-text-style editing, Markdown rendering, images, tags, reminders, search, random review, knowledge graph, and optional AI features.',
    },
    'isDataSafe': {'zh': '数据安全吗？', 'en': 'Is data safe?'},
    'isDataSafeAnswer': {
      'zh': '我们使用加密传输保护您的数据安全。本地数据也经过安全存储。建议定期备份重要笔记。',
      'en':
          'We use encrypted transmission to protect your data security. Local data is also stored securely. Regular backups of important notes are recommended.',
    },
    'whatIfForgotPassword': {
      'zh': '忘记密码怎么办？',
      'en': 'What if I forget my password?',
    },
    'whatIfForgotPasswordAnswer': {
      'zh': '请联系你的服务器管理员重置密码。',
      'en': 'Please contact your server administrator to reset your password.',
    },
    'anyOtherQuestions': {'zh': '还有其他问题？', 'en': 'Any other questions?'},
    'viewHelpCenter': {'zh': '查看帮助中心', 'en': 'View Help Center'},

    // ===== Home页面 =====
    'createNoteFailed': {'zh': '创建笔记失败', 'en': 'Failed to create note'},
    'syncSuccess': {'zh': '同步成功', 'en': 'Sync successful'},
    'refreshSuccess': {'zh': '刷新成功', 'en': 'Refresh successful'},
    'refreshFailed': {'zh': '刷新失败', 'en': 'Refresh failed'},
    'periodicReview': {'zh': '回顾', 'en': 'Review'},
    'askNotes': {'zh': '问笔记', 'en': 'Ask notes'},
    'askNotesHint': {'zh': '问问你的笔记…', 'en': 'Ask your notes…'},
    'reviewGenerating': {'zh': '正在生成回顾…', 'en': 'Generating review…'},
    'reviewRegenerate': {'zh': '重新生成', 'en': 'Regenerate'},
    'reviewCopy': {'zh': '复制', 'en': 'Copy'},
    'periodicReviewCopied': {'zh': '已复制', 'en': 'Copied'},
    'reviewNoNotes': {'zh': '这个周期还没有笔记', 'en': 'No notes in this period'},
    'periodicReviewPrompt': {'zh': '回顾提示词', 'en': 'Review prompt'},
    'periodicReviewPromptHint': {
      'zh': '用于侧边栏「回顾」里的周回顾 / 月回顾，留空使用默认提示词',
      'en':
          'Used by the weekly/monthly review in the sidebar. Leave empty for default.',
    },
    'relatedNotes': {'zh': '相关笔记', 'en': 'Related'},
    'findingRelatedNotes': {'zh': '正在查找相关笔记…', 'en': 'Finding related notes…'},
    'newestFirst': {'zh': '创建时间：从新到旧', 'en': 'Created: newest first'},
    'oldestFirst': {'zh': '创建时间：从旧到新', 'en': 'Created: oldest first'},
    'updatedTime': {'zh': '编辑时间：从新到旧', 'en': 'Edited: newest first'},
    'oldestEdited': {'zh': '编辑时间：从旧到新', 'en': 'Edited: oldest first'},
    'createFailed': {'zh': '创建失败', 'en': 'Create failed'},
    'addedFromShare': {'zh': '已添加来自分享的笔记', 'en': 'Added note from share'},
    'updateFailed': {'zh': '更新失败', 'en': 'Update failed'},
    'noteDeleted': {'zh': '笔记已删除', 'en': 'Note deleted'},
    'deleteFailed': {'zh': '删除失败', 'en': 'Delete failed'},
    'loadedAllNotes': {
      'zh': '已加载全部 {count} 条笔记',
      'en': 'Loaded all {count} notes',
    },

    // ===== 笔记详情页面 =====
    'unableToOpenLink': {'zh': '无法打开链接', 'en': 'Unable to open link'},
    'linkError': {'zh': '链接错误', 'en': 'Link error'},
    'noteUpdated': {'zh': '笔记已更新', 'en': 'Note updated'},
    'edit': {'zh': '编辑', 'en': 'Edit'},
    'copyContent': {'zh': '复制内容', 'en': 'Copy Content'},
    'aiReview': {'zh': 'AI点评', 'en': 'AI Review'},
    'notLoggedInOrAPINotInitialized': {
      'zh': '未登录或API服务未初始化',
      'en': 'Not logged in or API service not initialized',
    },
    'currentUserInfoEmpty': {
      'zh': '当前用户信息为空',
      'en': 'Current user information is empty',
    },
    'userInfoSyncSuccess': {
      'zh': '用户信息同步成功',
      'en': 'User information synchronized successfully',
    },
    'allAPIVersionsUpdateFailed': {
      'zh': '所有API版本更新失败',
      'en': 'All API versions failed to update',
    },
    'allPasswordUpdateFailed': {
      'zh': '所有API版本密码更新失败',
      'en': 'All API versions failed to update password',
    },

    // ===== 实验室页面 =====

    // AI 智能助手

    'testing': {'zh': '测试中', 'en': 'Testing'},

    'iKnow': {'zh': '我知道了', 'en': 'I Know'},

    // ===== AI设置页面 =====

    // ===== 设置页面 =====
    // 设置页标语：拆成「引导句 + 高亮句」两段排版，
    // key 名沿用历史命名，值已替换为当前标语。
    'waitPatiently': {'zh': '记录是为了', 'en': 'Write to become'},
    'poiseToResound': {'zh': '成为更好的自己', 'en': 'a better you'},

    // ===== NoteEditor Widget =====
    'editorPlaceholder': {'zh': '现在的想法是...', 'en': "What's on your mind..."},
    'saveFailed': {'zh': '保存失败', 'en': 'Save failed'},
    'selectImageFailed': {'zh': '选择图片失败', 'en': 'Failed to select image'},
    'noteNotFound': {'zh': '找不到要引用的笔记', 'en': 'Referenced note not found'},
    'pinned': {'zh': '置顶', 'en': 'Pinned'},
    'unpinned': {'zh': '取消置顶', 'en': 'Unpinned'},
    'later': {'zh': '稍后', 'en': 'Later'},

    // ===== 权限引导对话框 =====
    'permissionsReady': {'zh': '✅ 权限已就绪', 'en': '✅ Permissions Ready'},
    'permissionsRequired': {'zh': '需要权限', 'en': 'Permissions Required'},
    'allPermissionsGrantedMessage': {
      'zh': '所有权限已开启，可以正常使用提醒功能',
      'en': 'All permissions granted, reminders are ready to use',
    },
    'pleaseEnablePermissionsMessage': {
      'zh': '为了准时收到笔记提醒，请开启以下权限',
      'en':
          'To receive timely note reminders, please enable the following permissions',
    },
    'notificationPermission': {'zh': '通知权限', 'en': 'Notification Permission'},
    'allowAppNotifications': {
      'zh': '允许应用显示通知',
      'en': 'Allow app to show notifications',
    },
    'exactAlarm': {'zh': '精确闹钟', 'en': 'Exact Alarm'},
    'allowExactAlarmDescription': {
      'zh': '允许在特定时间触发提醒',
      'en': 'Allow reminders at specific times',
    },
    'backgroundRunning': {'zh': '后台运行', 'en': 'Background Running'},
    'allowBackgroundDescription': {
      'zh': '允许应用在后台保持活跃',
      'en': 'Allow app to stay active in background',
    },
    'openSettingsInstructions': {
      'zh': '点击下方"打开设置"按钮，在应用设置中开启权限后，点击"重新检查"',
      'en':
          'Click "Open Settings" below, enable permissions in app settings, then click "Recheck"',
    },
    'openSettings': {'zh': '打开设置', 'en': 'Open Settings'},
    'recheck': {'zh': '重新检查', 'en': 'Recheck'},
    'postponeSettings': {'zh': '稍后设置', 'en': 'Postpone'},

    // ===== NoteCard侧滑按钮 =====
    'noteCreatedSuccess': {'zh': '笔记已创建', 'en': 'Note created'},
    'sharePermissionConfirmation': {
      'zh': '分享权限确认',
      'en': 'Share Permission Confirmation',
    },
    'sharePermissionMessage': {
      'zh': '要分享此笔记，需要将其设置为公开状态。\n任何拥有链接的人都可以查看该笔记的内容。',
      'en':
          'To share this note, it needs to be set to public.\nAnyone with the link can view the note content.',
    },
    'confirmAndShare': {'zh': '确定并分享', 'en': 'Confirm and Share'},
    'savingImage': {'zh': '正在保存图片...', 'en': 'Saving image...'},
    'changeTime': {'zh': '修改时间', 'en': 'Change Time'},
    'selectDate': {'zh': '选择日期', 'en': 'Select Date'},
    'selectTime': {'zh': '选择时间', 'en': 'Select Time'},
    'timeUpdated': {'zh': '时间已更新', 'en': 'Time Updated'},
    'viewOriginalImage': {'zh': '查看原图', 'en': 'View Original'},
    'saveImage': {'zh': '保存图片', 'en': 'Save Image'},
    'loadingHDImage': {'zh': '正在加载高清原图...', 'en': 'Loading HD image...'},
    'imageLoadError': {'zh': '无法加载图片', 'en': 'Failed to load image'},
    'cannotDisplayImage': {'zh': '无法显示图片', 'en': 'Cannot display image'},
    'timeUpdateFailed': {'zh': '时间更新失败', 'en': 'Time Update Failed'},
    'share': {'zh': '分享', 'en': 'Share'},
    'cancel': {'zh': '取消', 'en': 'Cancel'},
    'generatingShareLink': {
      'zh': '正在生成分享链接...',
      'en': 'Generating share link...',
    },
    'reviewCopiedShort': {'zh': '✨ 点评已复制', 'en': '✨ Review copied'},
    'aiReviewCompleted': {'zh': '✨ AI点评完成！', 'en': '✨ AI review ready!'},
    'aiReviewTitle': {'zh': '给你的点评', 'en': 'Your Review'},
    'aiReadingNote': {'zh': 'AI正在阅读笔记...', 'en': 'AI is reading...'},
    'startInsightWithCount': {
      'zh': '开始洞察 ({count} 条笔记)',
      'en': 'Start Insight ({count} notes)',
    },
    'loadFailed': {'zh': '加载失败', 'en': 'Load Failed'},

    // ===== 版本更新 =====
    'latestVersion': {
      'zh': '最新版本：{version}',
      'en': 'Latest version: {version}',
    },

    // ===== 分享相关 =====
    'sharedText': {'zh': '收到分享的文本', 'en': 'Received shared text'},
    'sharedImagesCount': {
      'zh': '来自分享的图片 ({count}张)',
      'en': 'Shared images ({count})',
    },

    // ===== 排序和筛选 =====

    // ===== 登录状态 =====
    'online': {'zh': '在线', 'en': 'Online'},
    'offline': {'zh': '离线', 'en': 'Offline'},
    'clearLocalData': {'zh': '清空本地数据', 'en': 'Clear Local Data'},
    'keepLocalData': {'zh': '保留本地数据', 'en': 'Keep Local Data'},

    // ===== 功能菜单 =====

    // ===== AI洞察相关 =====
    'keywords': {'zh': '关键词', 'en': 'Keywords'},

    // ===== 权限和设置提示 =====
    'permissionRequired': {
      'zh': '需要通知权限',
      'en': 'Notification Permission Required',
    },
    'view': {'zh': '查看', 'en': 'View'},

    // ===== 通知相关 =====

    // ===== 时间相关 =====
    'last7Days': {'zh': '近7天', 'en': 'Last 7 Days'},
    'last30Days': {'zh': '近30天', 'en': 'Last 30 Days'},

    // ===== 笔记详情页 =====
    'noteDetail': {'zh': '笔记详情', 'en': 'Note Details'},
    'linkNote': {'zh': '链接', 'en': 'Link'},
    'referenceDetails': {'zh': '引用详情', 'en': 'Reference Details'},
    'detailedInfo': {'zh': '详细信息', 'en': 'Detailed Info'},
    'localAiPreferences': {'zh': '本地 AI 学习偏好', 'en': 'Local AI Preferences'},
    'localAiPreferencesDetail': {
      'zh': '记录你在应用内的浏览习惯——点开了哪些笔记、停留多久、从哪里进入，'
          '并据此调整「相关笔记」的推荐排序：你常看的标签和关系类型会被适当提前。'
          '所有数据仅保存在本机，不上传、不参与同步，可随时一键清除。',
      'en': 'Learns how you browse — which notes you open, how long you stay '
          'and where you came from — then re-ranks related-note suggestions '
          'toward your favorite tags and relation types. All data stays on '
          'this device: nothing is uploaded or synced, and you can clear it '
          'any time.',
    },
    'noteHistory': {'zh': '历史版本', 'en': 'Version History'},
    'noHistory': {'zh': '暂无历史版本', 'en': 'No version history'},
    'noHistoryHint': {
      'zh': '每次保存和编辑过程都会自动留档，\n最多保留 20 份、30 天内的版本',
      'en':
          'Snapshots are taken on save and while editing.\nUp to 20 versions within 30 days are kept.',
    },
    'restoreVersion': {'zh': '恢复此版本', 'en': 'Restore This Version'},
    'versionRestored': {'zh': '已恢复该版本', 'en': 'Version restored'},
    'createdTime': {'zh': '创建时间', 'en': 'Created Time'},
    'characterCount': {'zh': '字符数量', 'en': 'Character Count'},
    'characters': {'zh': '字符', 'en': 'characters'},
    'tagCount': {'zh': '标签数量', 'en': 'Tag Count'},
    'shareImage': {'zh': '分享图片', 'en': 'Share Image'},

    // ===== AI提示词 =====

    // ===== 笔记编辑器 =====
    'image': {'zh': '图片', 'en': 'Image'},
    'addNoteReference': {'zh': '添加笔记引用', 'en': 'Add Note Reference'},
    'selectNoteToReference': {
      'zh': '选择要引用的笔记，建立笔记间的关联关系',
      'en': 'Select a note to reference and create connections',
    },
    'noNotesToReference': {'zh': '暂无笔记可引用', 'en': 'No notes to reference'},
    'noMatchingNotes': {'zh': '没有找到相关笔记', 'en': 'No matching notes found'},

    // ===== NoteCard相关 =====
    'expand': {'zh': '展开', 'en': 'Expand'},
    'collapse': {'zh': '收起', 'en': 'Collapse'},
    'fullText': {'zh': '展开', 'en': 'Expand'},

    // ===== Preferences相关 =====
    'unknown': {'zh': '未知', 'en': 'Unknown'},
    'syncInterval': {'zh': '同步间隔', 'en': 'Sync Interval'},
    'rememberPasswordEnabled': {
      'zh': '已同时开启记住密码功能',
      'en': 'Remember password enabled',
    },

    // ===== AccountInfo相关 =====
    'avatarUpdated': {'zh': '头像已更新', 'en': 'Avatar updated'},
    'modifyNickname': {'zh': '修改昵称', 'en': 'Modify Nickname'},
    'pleaseEnterNewNickname': {
      'zh': '请输入新的昵称',
      'en': 'Please enter new nickname',
    },
    'nicknameUpdateSuccess': {
      'zh': '昵称更新成功',
      'en': 'Nickname updated successfully',
    },
    'nicknameUpdateFailed': {'zh': '昵称更新失败', 'en': 'Failed to update nickname'},
    'modifyEmail': {'zh': '修改邮箱', 'en': 'Modify Email'},
    'pleaseEnterNewEmail': {
      'zh': '请输入新的邮箱地址',
      'en': 'Please enter new email address',
    },
    'userInfoSyncFailed': {'zh': '同步失败', 'en': 'Sync failed'},
    'resourceServiceNotInitialized': {
      'zh': '资源服务未初始化',
      'en': 'Resource service is not initialized',
    },
    'uploadedAvatarUrlMissing': {
      'zh': '无法获取上传的头像URL',
      'en': 'Unable to get uploaded avatar URL',
    },
    'uploadAvatarFailed': {
      'zh': '上传头像失败',
      'en': 'Failed to upload avatar',
    },
    'emailUpdateSuccess': {
      'zh': '邮箱更新成功',
      'en': 'Email updated successfully',
    },
    'emailUpdateFailed': {
      'zh': '邮箱更新失败',
      'en': 'Failed to update email',
    },
    'currentPasswordLabel': {'zh': '当前密码', 'en': 'Current password'},
    'enterCurrentPassword': {
      'zh': '请输入当前密码',
      'en': 'Please enter current password',
    },
    'enterNewPassword': {
      'zh': '请输入新密码',
      'en': 'Please enter new password',
    },
    'enterNewPasswordWithMin': {
      'zh': '请输入新密码（至少3位）',
      'en': 'Please enter new password (at least 3 characters)',
    },
    'confirmNewPassword': {'zh': '确认新密码', 'en': 'Confirm new password'},
    'enterNewPasswordAgain': {
      'zh': '请再次输入新密码',
      'en': 'Please enter new password again',
    },
    'newPasswordTooShort': {
      'zh': '新密码至少需要3位',
      'en': 'New password must be at least 3 characters',
    },
    'newPasswordMismatch': {
      'zh': '两次输入的新密码不一致',
      'en': 'The new passwords do not match',
    },
    'newPasswordSameAsCurrent': {
      'zh': '新密码不能与当前密码相同',
      'en': 'New password cannot be the same as current password',
    },
    'passwordUpdateSuccessRelogin': {
      'zh': '密码修改成功，请重新登录',
      'en': 'Password updated. Please log in again.',
    },
    'passwordUpdateFailedCheckCurrent': {
      'zh': '密码修改失败，请检查当前密码是否正确',
      'en': 'Failed to update password. Please check the current password.',
    },
    'passwordUpdateFailed': {
      'zh': '密码修改失败',
      'en': 'Failed to update password',
    },
    'routeErrorTitle': {'zh': '错误', 'en': 'Error'},
    'invalidTagName': {'zh': '标签名称无效', 'en': 'Invalid tag name'},
    'pageLoadFailed': {'zh': '页面加载失败', 'en': 'Failed to load page'},
    'pageNotFound': {'zh': '页面未找到', 'en': 'Page not found'},
    'pageLost': {'zh': '哎呀，页面走丢了!', 'en': 'This page is missing.'},
    'requestPath': {'zh': '请求路径: {path}', 'en': 'Request path: {path}'},
    'saveImageToGallery': {
      'zh': '保存图片到相册',
      'en': 'Save image to Photos',
    },
    'storagePermissionRequiredForImage': {
      'zh': '需要存储权限才能保存图片',
      'en': 'Storage permission is required to save images',
    },
    'imageSavedToGallery': {
      'zh': '图片已保存到相册',
      'en': 'Image saved to Photos',
    },
    'saveImageFailed': {'zh': '保存图片失败', 'en': 'Failed to save image'},
    'downloadImageFailed': {
      'zh': '下载图片失败',
      'en': 'Failed to download image',
    },
    'imageDataEmpty': {'zh': '图片数据为空', 'en': 'Image data is empty'},
    'imagePathInvalid': {
      'zh': '图片路径已失效',
      'en': 'Image path is no longer valid',
    },
    'imageNotFound': {'zh': '图片不存在', 'en': 'Image not found'},
    'referenceNoteMissing': {
      'zh': '引用的笔记不存在或已被删除 (ID: {id})',
      'en': 'The referenced note does not exist or was deleted (ID: {id})',
    },
    'addLink': {'zh': '添加链接', 'en': 'Add link'},
    'displayText': {'zh': '显示文字', 'en': 'Display text'},
    'linkAddress': {'zh': '链接地址', 'en': 'Link URL'},

    // ===== SnackBarUtils相关 =====
    'connectionTimeout': {
      'zh': '连接超时，请检查网络或稍后重试',
      'en': 'Connection timeout, please check network or try again later',
    },

    // ===== DatabaseService相关 =====

    // ===== 引用关系相关 =====
    'referenceRelations': {'zh': '引用关系', 'en': 'Reference Relations'},
    'referenceCreated': {'zh': '引用关系已创建', 'en': 'Reference created'},
    'referenceFailed': {'zh': '引用失败', 'en': 'Reference failed'},
    'references': {'zh': '引用关系', 'en': 'References'},

    // ===== 侧滑操作 =====
    'reminder': {'zh': '提醒', 'en': 'Remind'},

    // ===== 关于我们 =====
    'emailAddress': {'zh': '电子邮件', 'en': 'Email Address'},
    'wechat': {'zh': '微信', 'en': 'WeChat'},

    // ===== 导入导出 =====
    'selectImportMethod': {'zh': '选择导入方式', 'en': 'Select Import Method'},

    // ===== 笔记详情页-提醒相关 =====
    'reminderSet': {'zh': '提醒已设置', 'en': 'Reminder Set'},
    'setReminder': {'zh': '设置提醒', 'en': 'Set Reminder'},
    'currentReminderTime': {'zh': '当前提醒时间', 'en': 'Current Reminder Time'},
    'enableNotificationFirst': {
      'zh': '请先开启通知权限才能设置提醒',
      'en': 'Please enable notification permission first',
    },
    'reminderTimeMustBeFuture': {
      'zh': '提醒时间必须在未来',
      'en': 'Reminder time must be in the future',
    },

    // ===== 笔记详情页-详细信息 =====

    // ===== 笔记详情页-分享相关 =====
    'linkCopied': {'zh': '链接已复制', 'en': 'Link copied'},
    'generateShareLinkFailed': {
      'zh': '生成分享链接失败，请稍后再试',
      'en': 'Failed to generate share link, please try again later',
    },
    'serverUrlEmpty': {'zh': '服务器地址为空', 'en': 'Server URL is empty'},

    // ===== 数据清理页面 =====
    'resetSettingsDescription': {
      'zh': '将所有应用设置恢复到默认状态，不会删除笔记数据',
      'en': 'Reset all app settings to default, note data will not be deleted',
    },

    // ===== AI设置页面 =====

    // ===== 首页其他 =====

    // ===== Flomo导入页面 =====
    'flomoNoteImport': {'zh': 'Flomo 笔记导入', 'en': 'Flomo Note Import'},
    'importInstructions': {'zh': '导入说明', 'en': 'Import Instructions'},
    'flomoImportStep1': {
      'zh': '1. 在 Flomo 应用中，进入"设置 > 账号详情 > 导出所有数据"',
      'en': '1. In Flomo app, go to "Settings > Account > Export All Data"',
    },
    'flomoImportStep2': {
      'zh': '2. 导出后会得到一个包含 HTML 文件和 file 目录的文件夹',
      'en':
          '2. You will get a folder containing HTML files and a file directory',
    },
    'flomoImportStep3': {
      'zh': '3. 📁 把整个导出文件夹解压到手机的下载目录或存储根目录',
      'en':
          '3. 📁 Unzip the entire export folder into the Downloads folder or storage root',
    },
    'flomoImportStep4': {
      'zh': '4. 点击下方"选择Flomo导出文件夹"按钮',
      'en': '4. Tap "Select Flomo Export Folder" button below',
    },
    'flomoImportStep5': {
      'zh': '5. 标签会自动识别（以 # 开头的文本）',
      'en': '5. Tags will be auto-detected (text starting with #)',
    },
    'flomoExportWarning': {
      'zh': 'Flomo 每 7 天只能导出一次，请妥善保管导出的文件',
      'en':
          'Flomo can only export once every 7 days, please keep the exported files safe',
    },
    'selectFile': {'zh': '选择文件', 'en': 'Select File'},
    'selectFlomoExportFolder': {
      'zh': '选择 Flomo 导出文件夹',
      'en': 'Select Flomo Export Folder',
    },
    'imageFileMissing': {'zh': '图片文件缺失', 'en': 'Image Files Missing'},
    'possibleReasons': {'zh': '可能原因：', 'en': 'Possible reasons:'},
    'htmlAndFileSeparated': {
      'zh': '• HTML文件和file目录不在同一位置',
      'en': '• HTML file and file directory are separated',
    },
    'fileFolderMoved': {
      'zh': '• file目录被移动或删除',
      'en': '• file directory was moved or deleted',
    },
    'exportDataIncomplete': {
      'zh': '• 导出数据不完整',
      'en': '• Export data is incomplete',
    },
    'solutionTip': {'zh': '💡 解决方法：', 'en': '💡 Solution:'},
    'ensureHtmlAndFile': {
      'zh': '1. 确保Flomo导出的HTML文件和file目录在同一文件夹中',
      'en': '1. Ensure HTML file and file directory are in the same folder',
    },
    'reselectFolder': {
      'zh': '2. 重新点击"选择Flomo导出文件夹"，选择包含HTML和file目录的整个文件夹',
      'en': '2. Re-select the folder containing both HTML and file directory',
    },
    'doNotMoveFiles': {
      'zh': '3. 不要单独移动HTML文件或file目录',
      'en': '3. Do not move HTML file or file directory separately',
    },
    'importOptions': {'zh': '导入选项', 'en': 'Import Options'},
    'preserveTags': {'zh': '保留标签', 'en': 'Preserve Tags'},
    'preserveTagsDesc': {
      'zh': '将 Flomo 中的 # 标签导入为笔记标签',
      'en': 'Import # tags from Flomo as note tags',
    },
    'preserveTime': {'zh': '保留时间', 'en': 'Preserve Time'},
    'preserveTimeDesc': {
      'zh': '尽可能保留笔记的创建时间',
      'en': 'Preserve note creation time if possible',
    },
    'importAsNew': {'zh': '作为新笔记导入', 'en': 'Import as New Notes'},
    'importAsNewDesc': {
      'zh': '所有导入的笔记将作为新笔记添加',
      'en': 'All imported notes will be added as new notes',
    },
    'importImages': {'zh': '导入图片', 'en': 'Import Images'},
    'importImagesDesc': {
      'zh': '导入笔记中的图片附件（图片会被复制到本地存储）',
      'en': 'Import image attachments (images will be copied to local storage)',
    },
    'smartDeduplication': {'zh': '智能去重', 'en': 'Smart Deduplication'},
    'detectDuplicates': {'zh': '检测重复笔记', 'en': 'Detect Duplicates'},
    'detectDuplicatesDesc': {
      'zh': '基于内容和时间智能识别重复笔记',
      'en': 'Intelligently detect duplicates based on content and time',
    },
    'whenDuplicatesFound': {'zh': '发现重复笔记时：', 'en': 'When duplicates found:'},
    'autoSkip': {'zh': '自动跳过', 'en': 'Auto Skip'},
    'autoSkipDesc': {
      'zh': '静默跳过所有重复笔记',
      'en': 'Silently skip all duplicates',
    },
    'askMe': {'zh': '询问我', 'en': 'Ask Me'},
    'askMeDesc': {
      'zh': '让我选择要导入哪些重复笔记（推荐）',
      'en': 'Let me choose which duplicates to import (recommended)',
    },
    'importAll': {'zh': '全部导入', 'en': 'Import All'},
    'importAllDesc': {
      'zh': '忽略重复检测，全部作为新笔记导入',
      'en': 'Ignore duplicates, import all as new notes',
    },
    'notePreview': {'zh': '笔记预览（前5条）', 'en': 'Note Preview (First 5)'},
    'startImport': {'zh': '开始导入', 'en': 'Start Import'},
    'dirNotExist': {'zh': '目录不存在', 'en': 'Directory does not exist'},
    'selectFolderFailed': {
      'zh': '选择文件夹失败',
      'en': 'Failed to select folder',
    },
    'fileNotExist': {'zh': '文件不存在', 'en': 'File does not exist'},
    'selectFileFailed': {
      'zh': '选择文件失败',
      'en': 'Failed to select file',
    },
    'previewFileFailed': {
      'zh': '预览文件失败',
      'en': 'Failed to preview file',
    },
    'noValidNotesInFile': {
      'zh': '文件中没有找到有效的笔记内容',
      'en': 'No valid notes found in file',
    },
    'pleaseSelectFileFirst': {
      'zh': '请先选择文件',
      'en': 'Please select a file first',
    },
    'userCancelledImport': {
      'zh': '用户取消导入',
      'en': 'Import cancelled by user',
    },
    'importFailed': {'zh': '导入失败', 'en': 'Import Failed'},
    'importSuccessful': {'zh': '导入成功', 'en': 'Import Successful'},
    'importedFromFlomo': {
      'zh': '成功从 Flomo 导入：',
      'en': 'Successfully imported from Flomo:',
    },
    'viewSkippedDuplicates': {
      'zh': '查看跳过的重复笔记',
      'en': 'View Skipped Duplicates',
    },
    'skippedDuplicates': {
      'zh': '跳过的重复笔记',
      'en': 'Skipped Duplicates',
    },
    'contentOnly': {'zh': '内容相同', 'en': 'Content Only'},
    'time': {'zh': '时间', 'en': 'Time'},
    'skipAll': {'zh': '全部跳过', 'en': 'Skip All'},
    'toImport': {'zh': '待导入', 'en': 'To Import'},
    'existing': {'zh': '已存在', 'en': 'Existing'},
    'tryOtherKeywords': {
      'zh': '尝试使用其他关键词搜索',
      'en': 'Try other keywords',
    },

    // ===== 标签页面 =====
    'noTagsYet': {'zh': '还没有任何标签', 'en': 'No tags yet'},
    'noMatchingTags': {'zh': '未找到匹配的标签', 'en': 'No matching tags'},
    'tagsHelp': {
      'zh': '标签可以帮助你更好地组织和查找笔记',
      'en': 'Tags help you organize and find notes better',
    },
    'howToUseTags': {'zh': '如何使用标签', 'en': 'How to Use Tags'},
    'expandAll': {'zh': '展开所有', 'en': 'Expand All'},
    'collapseAll': {'zh': '收起所有', 'en': 'Collapse All'},
    'expandAllTagsWithCount': {
      'zh': '展开全部 ({count}个标签)',
      'en': 'Expand All ({count} tags)',
    },
    'startWriting': {'zh': '开始写笔记', 'en': 'Start Writing'},

    // ===== 标签页面使用提示 =====
    'createTagByTyping': {
      'zh': '在笔记中输入 #标签名 创建标签',
      'en': 'Type #tagname in notes to create tags',
    },
    'hierarchicalTags': {
      'zh': '使用 / 创建层级标签，如 #工作/项目A',
      'en': 'Use / for hierarchical tags, e.g. #work/projectA',
    },
    'hierarchicalTagsShort': {
      'zh': '使用 / 创建层级标签（如 #工作/项目A）',
      'en': 'Use / for nested tags (e.g. #work/projectA)',
    },
    'clickTagToView': {
      'zh': '点击标签查看所有相关笔记',
      'en': 'Click tags to view related notes',
    },

    // ===== WebDAV设置页面 =====
    'custom': {'zh': '自定义', 'en': 'Custom'},
    'passwordAppSpecific': {
      'zh': '密码（应用专用密码）',
      'en': 'Password (App-Specific)',
    },
    'notLoginPassword': {
      'zh': '不是登录密码，需在服务商处生成',
      'en': 'Not the login password. Generate it from your service provider.',
    },
    'clickHelpIcon': {
      'zh': '点击右上角 ? 查看如何获取',
      'en': 'Tap ? for instructions',
    },

    // ===== 偏好设置页面 =====
    'sidebarCustomization': {'zh': '侧边栏', 'en': 'Sidebar'},
    'adjustMenuDisplay': {
      'zh': '调整菜单显示与排序',
      'en': 'Adjust menu display and sorting',
    },

    // ===== 侧边栏自定义页面 =====
    'customizeSidebar': {'zh': '自定义侧边栏', 'en': 'Customize Sidebar'},
    'headerComponents': {'zh': '头部组件', 'en': 'Header Components'},
    'showProfileCenter': {'zh': '显示个人中心', 'en': 'Show Profile Center'},
    'avatarUsernameLogin': {
      'zh': '头像、用户名和登录按钮',
      'en': 'Avatar, username and login button',
    },
    'showActivityLog': {'zh': '显示活动记录', 'en': 'Show Activity Log'},
    'showNoteCreationCalendar': {
      'zh': '展示笔记创建活动日历',
      'en': 'Show note creation activity calendar',
    },
    'menuItems': {'zh': '菜单项', 'en': 'Menu Items'},
    'longPressDragToReorder': {
      'zh': '长按拖动可调整顺序',
      'en': 'Long press and drag to reorder',
    },
    'confirmResetSidebar': {
      'zh': '确定要恢复侧边栏的默认设置吗？\n\n这将重置所有菜单项的显示状态和排序。',
      'en':
          'Reset sidebar to default settings?\n\nThis will reset all menu item visibility and sorting.',
    },
    'defaultHome': {'zh': '默认首页', 'en': 'Default Home'},
    'allNotesIsDefaultHome': {
      'zh': '💡 "全部笔记"是默认首页，无法隐藏或移动',
      'en': '💡 "All Notes" is the default home, cannot be hidden or moved',
    },
    'restoreDefaultSettings': {
      'zh': '恢复默认设置',
      'en': 'Restore Default Settings',
    },
    'profileOrSettingsRequired': {
      'zh': '个人中心和设置至少保留一个',
      'en': 'Keep at least Profile or Settings visible',
    },
    'defaultSettingsRestored': {
      'zh': '已恢复默认设置',
      'en': 'Default settings restored',
    },
    'sidebarConfigSaved': {
      'zh': '侧边栏配置已保存',
      'en': 'Sidebar config saved',
    },

    // ===== 通用弹窗与操作 =====
    'reset': {'zh': '重置', 'en': 'Reset'},

    // ===== 图片操作 =====
    'imageActionsTitle': {'zh': '图片操作', 'en': 'Image Actions'},
    'saveAction': {'zh': '保存', 'en': 'Save'},
    'preparingShareImage': {
      'zh': '准备分享图片...',
      'en': 'Preparing image...',
    },
    'imageShareText': {
      'zh': '来自 InkPaper 的图片分享',
      'en': 'Image shared from InkPaper',
    },
    'cannotGetImageFile': {
      'zh': '无法获取图片文件',
      'en': 'Cannot get image file',
    },
    'shareImageFailed': {
      'zh': '分享图片失败',
      'en': 'Failed to share image',
    },
    'savingFailed': {'zh': '保存失败', 'en': 'Save failed'},

    // ===== 分享图 =====
    'shareImageTitle': {'zh': '生成分享图', 'en': 'Generate Share Image'},
    'shareImageGeneratingPreview': {
      'zh': '正在生成预览（加载图片中...）',
      'en': 'Generating preview (loading images...)',
    },
    'shareImageLoadingImages': {
      'zh': '图片加载中，请稍候...',
      'en': 'Loading images, please wait...',
    },
    'shareImageGenerationFailed': {
      'zh': '预览生成失败',
      'en': 'Preview generation failed',
    },
    'shareImageChangeTemplate': {
      'zh': '更换模板',
      'en': 'Change Template',
    },
    'shareImageSave': {'zh': '保存图片', 'en': 'Save Image'},
    'shareImageShare': {'zh': '分享', 'en': 'Share'},
    'shareImageSaving': {'zh': '正在保存图片...', 'en': 'Saving image...'},
    'shareImageSaveFailed': {
      'zh': '保存失败，请检查权限或保存位置',
      'en': 'Save failed. Please check permissions or save location',
    },
    'shareImageShareFailed': {'zh': '分享失败', 'en': 'Share failed'},
    'shareImageWaitForPreview': {
      'zh': '请等待预览生成完成',
      'en': 'Please wait for preview to complete',
    },
    'shareImageFontSizeTitle': {'zh': '字体大小', 'en': 'Font Size'},
    'shareImageFontSizeDesc': {
      'zh': '拖动滑块实时预览效果',
      'en': 'Drag slider for live preview',
    },
    'shareImageFontSizeReset': {'zh': '重置 (17px)', 'en': 'Reset (17px)'},
    'shareImageFontSizeDone': {'zh': '完成', 'en': 'Done'},
    'shareImageFontSettings': {'zh': '字体设置', 'en': 'Font Settings'},
    'shareTemplateSimple': {'zh': '简约风格', 'en': 'Simple'},
    'shareTemplateCard': {'zh': '卡片风格', 'en': 'Card'},
    'shareTemplateGradient': {'zh': '渐变风格', 'en': 'Gradient'},
    'shareTemplateMinimal': {'zh': '极简风格', 'en': 'Minimal'},
    'shareTemplateMagazine': {'zh': '杂志风格', 'en': 'Magazine'},

    // ===== 标签配色 =====
    'presetColors': {'zh': '预设配色', 'en': 'Presets'},
    'backgroundColor': {'zh': '背景色', 'en': 'Background'},
    'textColor': {'zh': '文字色', 'en': 'Text'},

    // ===== 个性化页面 =====
    'personalization': {'zh': '个性化', 'en': 'Personalization'},
    'clearDataTooltip': {'zh': '清除数据', 'en': 'Clear data'},
    'clearAllDataTitle': {'zh': '清除所有数据', 'en': 'Clear all data'},
    'clearLearningPreferencesMessage': {
      'zh': '确定要清除所有学习偏好数据吗？这将重置个性化推荐。',
      'en':
          'Clear all learning preference data? This will reset personalized recommendations.',
    },
    'allDataCleared': {'zh': '已清除所有数据', 'en': 'All data cleared'},
    'noDataYet': {'zh': '暂无数据', 'en': 'No Data Yet'},
    'personalizationEmptyHint': {
      'zh': '开始使用相关笔记后，这里会显示你的使用统计',
      'en': 'After using related notes, your usage statistics will appear here',
    },
    'usageStats': {'zh': '使用统计', 'en': 'Usage Stats'},
    'totalClicks': {'zh': '总点击', 'en': 'Clicks'},
    'averageDuration': {'zh': '平均时长', 'en': 'Avg Duration'},
    'topTags': {'zh': '高频标签', 'en': 'Top Tags'},
    'relationTypes': {'zh': '关系类型', 'en': 'Relation Types'},
    'recentActivity': {'zh': '最近活动', 'en': 'Recent Activity'},
    'relationContinue': {'zh': '📚 延续学习', 'en': '📚 Continue'},
    'relationComplement': {'zh': '🧩 补充知识', 'en': '🧩 Complement'},
    'relationCompare': {'zh': '🔄 对比分析', 'en': '🔄 Compare'},
    'relationQa': {'zh': '❓ 问答', 'en': '❓ Q&A'},
    'relationPractice': {'zh': '🎯 实践', 'en': '🎯 Practice'},

    // ===== 性能看板 =====
    'performanceMonitoring': {'zh': '性能监控', 'en': 'Performance'},
    'performanceMetrics': {'zh': '性能指标', 'en': 'Metrics'},
    'currentFps': {'zh': '当前FPS', 'en': 'Current FPS'},
    'logStats': {'zh': '日志统计', 'en': 'Logs'},
    'errorCount': {'zh': '错误', 'en': 'Errors'},
    'warningCount': {'zh': '警告', 'en': 'Warnings'},
    'totalCount': {'zh': '总计', 'en': 'Total'},
    'recentErrors': {'zh': '最近错误:', 'en': 'Recent errors:'},
    'tracing': {'zh': '链路追踪', 'en': 'Tracing'},
    'recentOperationCount': {
      'zh': '最近操作: {count}个',
      'en': 'Recent operations: {count}',
    },
    'metricAppLaunch': {'zh': '应用启动', 'en': 'App Launch'},
    'metricPageLoad': {'zh': '页面加载', 'en': 'Page Load'},
    'metricNetworkRequest': {'zh': '网络请求', 'en': 'Network Request'},
    'metricDatabaseQuery': {'zh': '数据库查询', 'en': 'Database Query'},
    'metricImageLoad': {'zh': '图片加载', 'en': 'Image Load'},

    // ===== 语音识别 =====
    'suggestion': {'zh': '💡 建议', 'en': '💡 Suggestion'},

    // ===== Flomo 导入 =====
    'htmlFileNotFoundTitle': {
      'zh': '未找到HTML文件',
      'en': 'HTML file not found',
    },
    'htmlFileNotFoundMessage': {
      'zh':
          '在选择的文件夹中未找到HTML文件。\n\n这可能是Android文件访问权限问题。\n\n建议：请直接选择HTML文件而不是文件夹。',
      'en':
          'No HTML file was found in the selected folder.\n\nThis may be caused by Android file access permissions.\n\nSuggestion: Select the HTML file directly instead of a folder.',
    },
    'selectHtmlFile': {'zh': '选择HTML文件', 'en': 'Select HTML File'},

    // ===== 本地备份保存 =====
    'errorTitle': {'zh': '错误', 'en': 'Error'},
    'chooseSaveLocation': {'zh': '选择保存位置', 'en': 'Choose Save Location'},
    'userCancelledSave': {'zh': '用户取消保存', 'en': 'Save cancelled'},
    'fileSaveFailed': {'zh': '文件保存失败', 'en': 'Failed to save file'},
    'saveToAppDirectoryFailed': {
      'zh': '保存到应用目录失败',
      'en': 'Failed to save to app directory',
    },
    'backupShareSubject': {'zh': 'InkPaper-墨鸣笔记备份', 'en': 'InkPaper Backup'},
    'backupShareText': {
      'zh': '墨鸣笔记导出备份：{fileName}',
      'en': 'InkPaper backup export: {fileName}',
    },
    'fileSharedToSave': {
      'zh': '文件已通过分享发送，您可以选择保存到文件管理器',
      'en': 'File shared. You can save it to a file manager.',
    },
    'localSaveSuccessTitle': {'zh': '保存成功', 'en': 'Saved'},
    'fileSavedTo': {'zh': '文件已成功保存到：', 'en': 'File saved to:'},
    'findFileInManager': {
      'zh': '您可以在文件管理器中找到该文件。',
      'en': 'You can find this file in your file manager.',
    },
    'fileSavedTitle': {'zh': '文件已保存', 'en': 'File Saved'},
    'fileSavedToPrivateDirectory': {
      'zh': '文件已保存到应用私有目录：{fileName}',
      'en': 'File saved to the app private directory: {fileName}',
    },
    'androidSaveLimitHint': {
      'zh': '由于Android系统限制，建议您通过分享将文件保存到可访问的位置。',
      'en':
          'Due to Android system restrictions, use Share to save the file to an accessible location.',
    },
    'shareNow': {'zh': '立即分享', 'en': 'Share Now'},
    'localSaveFailedTitle': {
      'zh': '本地保存失败',
      'en': 'Local Save Failed',
    },
    'localSaveFailedMessage': {
      'zh': '无法将文件保存到本地存储。是否改用分享方式，您可以通过分享选择保存位置？',
      'en':
          'Unable to save the file locally. Use Share instead so you can choose a save location?',
    },
    'shareSave': {'zh': '分享保存', 'en': 'Share to Save'},

    // ===== WebDAV 操作反馈 =====
    'invalidServerAddress': {
      'zh': '服务器地址格式不正确',
      'en': 'Invalid server address',
    },
    'webdavHttpsRequired': {
      'zh': '请使用 https://。仅 localhost、127.0.0.1 和内网地址允许 http://',
      'en':
          'Use https://. http:// is allowed only for localhost and private LAN addresses.',
    },
    'syncPathMustStartWithSlash': {
      'zh': '同步路径必须以 / 开头',
      'en': 'Sync path must start with /',
    },
    'connectionTestSuccess': {
      'zh': '连接测试成功',
      'en': 'Connection test succeeded',
    },
    'connectionTestFailed': {
      'zh': '连接测试失败，请检查配置',
      'en': 'Connection test failed. Check your settings.',
    },
    'testFailed': {'zh': '测试失败', 'en': 'Test failed'},
    'backupCompleted': {'zh': '备份完成', 'en': 'Backup completed'},
    'restoreCompleted': {'zh': '恢复完成', 'en': 'Restore completed'},
    'backupFailed': {'zh': '备份失败', 'en': 'Backup failed'},
    'restoreFailed': {'zh': '恢复失败', 'en': 'Restore failed'},
    'backupServiceUnavailable': {
      'zh': '备份服务未初始化',
      'en': 'Backup service is not ready',
    },
    'restoreServiceUnavailable': {
      'zh': '恢复服务未初始化',
      'en': 'Restore service is not ready',
    },
    'webdavResourcesUploaded': {
      'zh': '资源：{count} 个',
      'en': 'Resources: {count}',
    },
    'webdavBackupNotesCount': {
      'zh': '笔记：{count} 条',
      'en': 'Notes: {count}',
    },
    'restoredNotesCount': {
      'zh': '已恢复：{count} 条笔记',
      'en': 'Restored: {count} notes',
    },
    'errorsCount': {'zh': '错误：{count}', 'en': 'Errors: {count}'},

    // ===== 最近删除（回收站） =====
    'recentlyDeleted': {'zh': '最近删除', 'en': 'Recently Deleted'},
    'recentlyDeletedEmpty': {
      'zh': '最近删除是空的',
      'en': 'Nothing in Recently Deleted',
    },
    'recentlyDeletedRetention': {
      'zh': '删除的笔记会在这里保留 {days} 天',
      'en': 'Deleted notes are kept here for {days} days',
    },
    'purgeForever': {
      'zh': '彻底删除',
      'en': 'Delete Permanently',
    },
    'purgeForeverMessage': {
      'zh': '这条笔记将被永久删除，无法恢复。',
      'en': "This note will be permanently deleted. This can't be undone.",
    },
    'purgeAllTitle': {
      'zh': '清空最近删除',
      'en': 'Empty Recently Deleted',
    },
    'purgeAllMessage': {
      'zh': '最近删除中的 {count} 条笔记将被永久删除，无法恢复。',
      'en':
          "{count} notes in Recently Deleted will be permanently deleted. This can't be undone.",
    },
    'purgeAllAction': {'zh': '全部删除', 'en': 'Delete All'},
    'purgeAllSuccess': {
      'zh': '已彻底删除 {count} 条笔记',
      'en': 'Permanently deleted {count} notes',
    },
    'notePurged': {'zh': '已彻底删除', 'en': 'Permanently deleted'},
    'restoreAction': {'zh': '恢复', 'en': 'Restore'},
    'restoreFailedRetry': {
      'zh': '恢复失败，请重试',
      'en': 'Restore failed, please try again',
    },
    'deleteFailedRetry': {
      'zh': '删除失败，请重试',
      'en': 'Delete failed, please try again',
    },
    'deletedAtLabel': {'zh': '删除于 {time}', 'en': 'Deleted {time}'},
    'deletedAtUnknown': {
      'zh': '删除时间未知',
      'en': 'Deletion time unknown',
    },
    'noteCharCount': {'zh': '共 {count} 字', 'en': '{count} characters'},
    'untitledNote': {'zh': '无标题笔记', 'en': 'Untitled note'},
    'emptyTrashAction': {'zh': '清空', 'en': 'Empty'},
    'recentlyDeletedNoDeleted': {
      'zh': '没有已删除的笔记',
      'en': 'No deleted notes',
    },
    // ===== 首页欢迎笔记 =====
    'welcomeNoteContent': {
      'zh': '小纸是一款面向个人知识记录的 Android 笔记应用。'
          '它可以本地优先使用，也可以连接自托管 Memos 服务进行同步。'
          '应用提供 Memos 兼容 Markdown、图片、标签、提醒、搜索、WebDAV 备份、'
          '导入导出、系统分享、小组件和可选 AI 辅助等能力。'
          '（本条笔记在您正式使用后会自动删除）',
      'en': 'InkPaper is an Android note app for personal knowledge. '
          'It works local-first, and can sync with a self-hosted Memos server. '
          'It supports Memos-compatible Markdown, images, '
          'tags, reminders, search, WebDAV backup, import/export, system share, '
          'widgets, and optional AI assistance. '
          '(This note disappears once you start using the app.)',
    },
    'welcomeNoteHint': {
      'zh': '这是示例笔记，创建第一条笔记后会自动消失',
      'en':
          'This is a sample note. It disappears after you create your first note.',
    },
    'noteComposerHint': {'zh': '记点什么…', 'en': 'Write something…'},
    // ===== 登录页校验与提示 =====
    'usernameRequired': {
      'zh': '请填写用户名，不能为空',
      'en': 'Please enter a username',
    },
    'usernameTooShort': {
      'zh': '用户名太短了，至少需要 2 个字符',
      'en': 'Username must be at least 2 characters',
    },
    'passwordRequired': {
      'zh': '请填写密码，不能为空',
      'en': 'Please enter a password',
    },
    'passwordTooShort': {
      'zh': '密码太短了，至少需要 6 位',
      'en': 'Password must be at least 6 characters',
    },
    'serverUrlRequired': {
      'zh': '请填写服务器地址，例如：https://demo.memos.app',
      'en': 'Please enter the server address, e.g. https://demo.memos.app',
    },
    'serverUrlInvalid': {
      'zh': '地址格式不对，需要以 https:// 开头\n示例：https://demo.memos.app',
      'en':
          'Invalid address, it must start with https://\ne.g. https://demo.memos.app',
    },
    'loginServerTips': {
      'zh': '✅ 支持常见 Memos 版本，并按检测结果选择接口\n'
          '🔒 建议使用 HTTPS，登录凭证会保存在系统安全存储中\n'
          '📱 登录并同步成功后，可在多个设备查看笔记',
      'en': '✅ Works with common Memos versions, picking the API automatically\n'
          '🔒 HTTPS is recommended; credentials are stored in secure storage\n'
          '📱 After signing in and syncing, your notes are available on all devices',
    },
    'loginHelpHint': {
      'zh': '遇到问题？点右上角 ? 查看常见问题解答',
      'en': 'Having trouble? Tap ? in the top-right corner for FAQ',
    },
    'loginMoreQuestions': {'zh': '还有其他问题？', 'en': 'More questions?'},
    'loginViewHelpCenter': {'zh': '查看帮助中心', 'en': 'Visit help center'},
    // ===== 笔记操作服务提示 =====
    'shareFailedDetail': {'zh': '分享失败: {error}', 'en': 'Share failed: {error}'},
    'serverConfigMissing': {
      'zh': '未登录或服务器配置错误',
      'en': 'Not signed in, or the server is misconfigured',
    },
    'localReviewUsed': {
      'zh': 'AI暂不可用，已使用本地点评',
      'en': 'AI is unavailable, showing the local review instead',
    },
    'localReview': {'zh': '本地点评', 'en': 'Local review'},
    // ===== 相对时间 =====
    'relativeJustNow': {'zh': '刚刚', 'en': 'just now'},
    'relativeMinutesAgo': {'zh': '{count} 分钟前', 'en': '{count} min ago'},
    'relativeHoursAgo': {'zh': '{count} 小时前', 'en': '{count} h ago'},
    'relativeDaysAgo': {'zh': '{count} 天前', 'en': '{count} d ago'},
    'relativeMonthsAgo': {'zh': '{count} 个月前', 'en': '{count} mo ago'},
    'relativeYearsAgo': {'zh': '{count} 年前', 'en': '{count} y ago'},
    'relativeTimeInParens': {'zh': '（{value}）', 'en': ' ({value})'},
  };

  /// 获取翻译文本
  /// [key] - 翻译键
  /// [languageCode] - 语言代码 (zh, en)
  /// [fallback] - 备用文本（可选）
  static String get(String key, String languageCode, {String? fallback}) {
    final translations = _translations[key];
    if (translations == null) {
      return fallback ?? key;
    }

    return translations[languageCode] ??
        translations['en'] ?? // 英文作为备选
        translations['zh'] ?? // 中文作为备选
        fallback ??
        key;
  }

  /// 检查是否支持某个语言
  static bool isLanguageSupported(String languageCode) =>
      languageCode == 'zh' || languageCode == 'en';

  /// 获取所有支持的语言代码
  static List<String> getSupportedLanguages() => ['zh', 'en'];
}
