# IntPaper Architecture Documentation

This directory contains the architecture documentation for IntPaper.

> 📌 **最新的完整架构解析与架构图见 [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md)**（2026-10，含分层总览图、Android 桥接图、启动时序、路由树、同步链路、SQLite ER 图、CI/CD 流水线，以及带 file:line 证据的风险清单）。
>
> 本文件中的部分数字已过期，下方已就地更正；文中引用的 `database-schema.md`、`security-design.md`、`performance.md`、`../TESTING.md` 目前**不存在**。

---

## 📋 Table of Contents

- [Architecture Overview](#architecture-overview)
- [Architecture Decision Records (ADR)](#architecture-decision-records-adr)
- [System Design](#system-design)
- [Data Flow](#data-flow)
- [Component Design](#component-design)

---

## 🏗️ Architecture Overview

IntPaper follows a **layered architecture** pattern with clear separation of concerns:

```
┌─────────────────────────────────────────────┐
│         Presentation Layer (UI)              │
│  • Screens (34 files)                        │
│  • Widgets (27 files)                        │
│  • Material Design 3                         │
└─────────────────────────────────────────────┘
                    ↓↑
┌─────────────────────────────────────────────┐
│      State Management Layer (Provider)       │
│  • AppProvider (Global State)                │
│  • Reactive Updates                          │
│  • Business Logic Coordination               │
└─────────────────────────────────────────────┘
                    ↓↑
┌─────────────────────────────────────────────┐
│       Business Logic Layer (Services)        │
│  • 54 Service Classes                        │
│  • API Integration                           │
│  • Business Rules                            │
└─────────────────────────────────────────────┘
                    ↓↑
┌──────────────────────┬──────────────────────┐
│   Local Data Layer   │  Remote Data Layer   │
│  • SQLite Database   │  • Memos API v1      │
│  • Secure Storage    │  • HTTP/HTTPS        │
│  • File System       │  • WebDAV            │
└──────────────────────┴──────────────────────┘
```

### Design Principles

1. **Separation of Concerns**: Each layer has a single responsibility
2. **Dependency Inversion**: High-level modules don't depend on low-level modules
3. **Single Source of Truth**: Provider manages all state
4. **Testability**: Layers are independently testable
5. **Scalability**: Easy to add new features without breaking existing code

---

## 📚 Architecture Decision Records (ADR)

ADRs document important architectural decisions. See [adr/README.md](adr/README.md) for the complete list.

### Key Decisions

| ADR | Title | Status |
|-----|-------|--------|
| [001](adr/001-use-provider-for-state-management.md) | Use Provider for State Management | Accepted |
| [002](adr/002-sqlite-for-local-storage.md) | Use SQLite for Local Storage | Accepted |
| [003](adr/003-memos-api-integration.md) | Integrate with Memos API v1 | Accepted |
| [004](adr/004-material-design-3.md) | Adopt Material Design 3 | Accepted |
| [005](adr/005-layered-architecture.md) | Implement Layered Architecture | Accepted |

### Creating New ADRs

See [ADR Template](adr/template.md) for guidelines on creating new architecture decision records.

---

## 🎯 System Design

### High-Level Components

```
┌─────────────────────────────────────────────────┐
│                   IntPaper App                    │
├─────────────────────────────────────────────────┤
│                                                  │
│  ┌──────────────┐  ┌──────────────┐            │
│  │  UI Layer    │  │   Providers  │            │
│  │  - Screens   │→←│  - AppState  │            │
│  │  - Widgets   │  │              │            │
│  └──────────────┘  └──────────────┘            │
│         ↓↑                 ↓↑                    │
│  ┌──────────────────────────────────┐          │
│  │        Service Layer              │          │
│  │  • DatabaseService                │          │
│  │  • ApiService                     │          │
│  │  • SyncService                    │          │
│  │  • AIService                      │          │
│  │  • NotificationService            │          │
│  │  • ... (54 services total)        │          │
│  └──────────────────────────────────┘          │
│         ↓↑                 ↓↑                    │
│  ┌─────────────┐    ┌─────────────┐            │
│  │   SQLite    │    │  Memos API  │            │
│  │   Database  │    │   Server    │            │
│  └─────────────┘    └─────────────┘            │
│                                                  │
└─────────────────────────────────────────────────┘
```

### Core Components

#### 1. Presentation Layer
- **Screens**: Full-page views (HomeScreen, NoteDetailScreen, etc.)
- **Widgets**: Reusable UI components (NoteCard, Sidebar, etc.)
- **Themes**: Styling and theming configuration

#### 2. State Management
- **Provider Pattern**: Central state management
- **AppProvider**: Global app state
- **Reactive Updates**: Automatic UI updates when state changes

#### 3. Business Logic
- **Services**: Encapsulate business logic
- **Separation**: Each service handles specific domain
- **Testable**: Services are independently testable

#### 4. Data Layer
- **Local**: SQLite database + Secure storage
- **Remote**: Memos API + WebDAV
- **Sync**: Two-way synchronization

---

## 🔄 Data Flow

### Note Creation Flow

```
User Taps + Button
       ↓
NoteEditorScreen
       ↓
User Writes Content
       ↓
AppProvider.createNote()
       ↓
DatabaseService.insertNote()
       ↓
SQLite Database
       ↓
[If Cloud Sync Enabled]
       ↓
ApiService.createNote()
       ↓
Memos Server
       ↓
AppProvider.notifyListeners()
       ↓
UI Updates Automatically
```

### Note Sync Flow

```
App Starts / User Pulls to Refresh
       ↓
AppProvider.syncNotes()
       ↓
ApiService.fetchNotes()
       ↓
Memos Server Returns Notes
       ↓
IncrementalSyncService.merge()
       ↓
DatabaseService.updateNotes()
       ↓
SQLite Database Updated
       ↓
AppProvider.notifyListeners()
       ↓
HomeScreen Rebuilds with New Data
```

### Voice Input Flow

```
User Taps Microphone Icon
       ↓
SpeechService.startListening()
       ↓
Platform Speech Recognition
       ↓
SpeechService.onResult()
       ↓
NoteEditor.insertText()
       ↓
User Continues Editing
```

---

## 🧩 Component Design

### Service Layer Design

Each service follows these principles:

1. **Single Responsibility**: Each service handles one domain
2. **Dependency Injection**: Dependencies passed via constructor
3. **Error Handling**: Comprehensive error handling
4. **Logging**: Detailed logging for debugging

**Example Service Structure**:

```dart
class NoteService {
  final DatabaseService _databaseService;
  final ApiService _apiService;
  final Logger _logger;

  NoteService(
    this._databaseService,
    this._apiService,
    this._logger,
  );

  Future<List<Note>> getAllNotes() async {
    try {
      _logger.info('Fetching all notes');
      return await _databaseService.getAllNotes();
    } catch (e) {
      _logger.error('Failed to fetch notes', error: e);
      rethrow;
    }
  }

  Future<Note> createNote(String content) async {
    // Implementation
  }

  Future<void> syncNotes() async {
    // Implementation
  }
}
```

### Widget Design

Widgets follow Flutter best practices:

1. **Composition over Inheritance**: Build complex UI from simple widgets
2. **Stateless when Possible**: Prefer StatelessWidget for pure UI
3. **const Constructors**: Use const for performance
4. **Separation of Logic**: Keep business logic in services

**Example Widget**:

```dart
class NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback? onTap;

  const NoteCard({
    Key? key,
    required this.note,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(note.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(note.content, maxLines: 3),
            ],
          ),
        ),
      ),
    );
  }
}
```

---

## 📊 Database Schema

> ⚠️ 更正（2026-10）：`database-schema.md` 不存在。实际数据库为单一 `notes.db`（schema v8），**只有两张表**：
>
> - **notes**：笔记主表（内容、时间、标签字符串、`resourceList`/`relations`/`annotations` 三个 JSON 列、`is_synced`、`isPinned`、`visibility`、`rowStatus`、`reminder_time`、`last_sync_time`）
> - **reminder_notifications**：提醒历史（外键 `note_id` ON DELETE CASCADE，2 个索引）
>
> 索引只有 2 个，且都在 `reminder_notifications` 上；`notes` 表没有索引。详见 [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) 的 §6「数据层」。

### ~~Main Tables~~（已作废，实际不存在的表：tags / note_tags / resources / sync_status）

- **notes**：Store note data
- **reminder_notifications**：Reminder history (the only other table)

---

## 🔐 Security Design

See [security-design.md](security-design.md) for detailed security architecture.

### Key Security Features

1. **Secure Storage**: Sensitive data encrypted
2. **HTTPS Only**: All network requests over HTTPS
3. **Token Management**: JWT tokens stored securely
4. **Input Validation**: All user input validated
5. **SQL Injection Prevention**: Parameterized queries

---

## ⚡ Performance Optimization

See [performance.md](performance.md) for detailed performance strategies.

### Optimization Techniques

1. **Lazy Loading**: Load data on demand
2. **Pagination**: Load notes in batches
3. **Image Caching**: Cache images locally
4. **Database Indexing**: Index frequently queried fields
5. **Widget Optimization**: Use const and keys appropriately

---

## 🧪 Testing Strategy

See [../TESTING.md](../TESTING.md) for complete testing documentation.

### Test Pyramid

- **Unit Tests (70%)**: Test individual functions and classes
- **Widget Tests (20%)**: Test UI components
- **Integration Tests (10%)**: Test feature workflows

---

## 📚 Additional Resources

- [Flutter Architecture Guide](https://flutter.dev/docs/development/data-and-backend/state-mgmt/intro)
- [Clean Architecture](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [Provider Package](https://pub.dev/packages/provider)

---

## 🤝 Contributing

When making architectural changes:

1. **Discuss First**: Open an issue to discuss major changes
2. **Document**: Update architecture documentation
3. **Create ADR**: Document decisions with an ADR
4. **Update Diagrams**: Keep architecture diagrams current
5. **Test**: Ensure changes don't break existing architecture

---

<div align="center">

**Architecture Documentation** | [IntPaper](https://github.com/yyyyymmmmm/IntPaper)

[Back to Main README](../../README.md) | [View ADRs](adr/README.md)

</div>

