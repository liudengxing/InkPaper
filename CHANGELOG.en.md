# Changelog

InkPaper release notes, written for the people using the app: what changed, not how it works.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Writing rules

1. **Write for users.** Only user-visible changes. No file names, class names, APIs, algorithms, dependency versions, CI config, test counts or lines of code.
2. **One item, one change.** Start with the feature name and say what it gives the user, in a single line under ~120 characters; never repeat or split the same change.
3. **Do not detail bug fixes.** Use the fixed sentence "Fixed known issues, improved stability and runtime efficiency." and list nothing specific.
4. **List new features and improvements one by one.** Each item states the feature name and the value the user can feel, never the implementation.
5. **Fixed sections and order**: `### Added`, `### Improved`, `### Fixed`, `### Removed`; omit empty sections.
6. **Internal-only releases** (build, tests, dependencies, CI) say only: "Internal maintenance release with no change in the user experience."
7. **Consistent wording**: items look like `- **Feature name**: what it gives you.`; release headings look like `## [1.1.87] - 2026-11-14` with no link references.

---

## [1.1.88] - 2026-11-14

### Improved

- **A cleaner About screen**: the large icon banner is gone; the page starts right with the introduction.
- **Colors matching the home screen**: cards and text use the same light-grey bordered style, no more brand green.
- **Account and sync combined**: connection status, sync now and connection diagnosis moved into the account screen, one fewer settings entry.
- **Sync toggles at hand**: auto sync, sync interval and auto login moved into the account screen, no more digging through preferences.
- **Laboratory refreshed**: Notion sync and Obsidian sync moved into the Laboratory, leaving the import/export page purely about backup and import.
- **Less brand green**: the help screen, home-screen top bar icons and the update/download dialog now use the same light-grey style as the home cards.
- **Page while zoomed**: drag a zoomed photo to its edge and keep going to flip to the next picture, no need to zoom out first.

### Removed

- **WeRead import retired**: importing notes from WeRead text is no longer supported and its screen has been removed.
- **Account deletion page removed**: it duplicated the data cleanup feature and no longer shows in settings.

## [1.1.87] - 2026-11-14

### Added

- **Update check record**: the About screen shows when the last check ran, which source answered and what it concluded, with the reason when it failed.
- **Restore a skipped reminder**: a version dismissed with "Later" can be restored, and later releases prompt again.

### Improved

- **Check right after upgrading**: a freshly installed version is no longer blocked by the previous version's timing record.
- **Less waiting when checking**: automatic checks run more often, prefer the domestic mirror and retry on the other source when it fails.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.86] - 2026-11-13

### Added

- **View built-in default prompt**: each custom prompt field can expand the default text, so you can copy it, edit it and paste it back.

### Improved

- **Faster images**: the home list, note detail and editor share one thumbnail, so cold starts and reopening notes are noticeably quicker.
- **Grid by default in the editor**: images open as a three-column grid whose height follows the number of rows, with drag-to-reorder that makes room as you move.
- **Lighter notes with images**: pictures load at display size, so long notes no longer stutter and use less memory.
- **Better text toolbar**: selecting text brings up the system-style capsule bar, and tapping the caret again opens copy/paste.
- **No dark flash on launch**: in light theme, and with the system in dark mode, the first frame already shows your chosen theme.
- **Paper-sheet icon is back**: launcher, notification and in-app marks share one dark-green paper shape.
- **Quieter "On this day" card**: it now uses the same thin grey border as ordinary notes instead of brand green.
- **Clearer "More" button**: it uses body text colour in light mode and stays light grey in dark mode.

### Removed

- InkPaper no longer appears in the system text-selection menu of other apps.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.85] - 2026-11-13

### Improved

- **Readable release notes**: the update dialog renders the notes as body text, so headings and lists no longer show raw markup.
- **Choose the download source**: the update dialog offers the domestic mirror or GitHub at the bottom, with the mirror selected by default.

## [1.1.84] - 2026-11-13

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.83] - 2026-11-13

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.82] - 2026-11-13

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.81] - 2026-11-13

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.80] - 2026-11-12

### Improved

- **Android only**: the app ships for Android alone, which means a smaller package and a simpler update chain.

### Removed

- The iOS, macOS, Windows and Linux builds, along with desktop-only layouts and share extensions.

## [1.1.13] - 2026-06-22

### Improved

- **Widget refreshes immediately**: settings changes take effect at once instead of at the next refresh.
- **More reliable share parsing**: text and multi-image shares from browsers and readers are no longer mistaken for attachments.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.12] - 2026-06-22

### Improved

- Internal maintenance release with no change in the user experience.

## [1.1.11] - 2026-06-22

### Added

- **iOS share extension**: send text, web pages and images from browsers, readers, Photos and the Files app.
- **Unified Android share entry**: text, web pages, single or multiple images, single or multiple files and mixed attachments are all accepted.

### Improved

- **Smoother large shares**: attachments are copied in the background with their file names kept, which reduces stutter.
- **Broader server support**: Memos 0.21 through 0.29 sign in and initialise more reliably.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.10] - 2026-06-22

### Added

- **Home-screen widgets**: quick capture and random review as separate widgets, ready without opening the app.
- **Configurable random review**: pick what the widget shows and how it refreshes, with real notes preferred.
- **Bring your own speech service**: enter your own iFlytek credentials and pay the service cost yourself.

### Improved

- **Easier knowledge graph**: clearer visuals, better zoom and node taps, and smoother rendering of large graphs.
- **Whole-interface scaling on desktop**: changing the font size now scales interface elements too.
- **Fuller Markdown rendering**: headings, quotes, links and underline display correctly in both list and detail.
- **Smoother tags**: path parsing, sidebar back navigation and Chinese tags all behave as expected.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.9] - 2026-06-16

### Improved

- Internal maintenance release with no change in the user experience.

## [1.1.8] - 2026-06-16

### Improved

- **More natural AI output**: review, summary, continuation and recap read less like a template.
- **Docs match the app**: About, Help, Settings and the legal pages now describe what the app actually does.
- **More stable images and layout**: preview, expand detection and the timestamps kept during backup and sync all improved.
- **Brand line restored**: "静待沉淀，蓄势而鸣" is back.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.7] - 2026-06-15

### Improved

- Internal maintenance release with no change in the user experience.

## [1.1.6] - 2026-06-15

### Improved

- Internal maintenance release with no change in the user experience.

## [1.1.5] - 2026-06-15

### Improved

- Internal maintenance release with no change in the user experience.

## [1.1.4] - 2026-06-15

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.3] - 2026-06-15

### Improved

- Internal maintenance release with no change in the user experience.

## [1.1.2] - 2026-06-15

### Added

- **Account and data deletion**: an in-app entry, plus a public page for requesting deletion.
- **Updated privacy documents**: they now match how servers, sync, WebDAV, AI and feedback actually handle data.

### Improved

- **Broader sign-in support**: the app adapts to the account API and authentication used by different server versions.
- **Clearer sign-in errors**: wrong password, bad token, network and server faults are reported separately.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.1.1] - 2026-06-15

### Improved

- **More reliable sign-in**: when a server hides its version, the app tries the other authentication protocol.
- **Consistent desktop icons**: Windows and macOS icons come from the same generation flow.

## [1.1.0] - 2026-06-14

### Improved

- **One maintenance command**: versioning, builds, releases and checks run through a single command.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.0.9] - 2025-11-22 ~ 2025-11-24

### Added

- **Notion sync**: two-way sync with a Notion workspace, one-way if you prefer, plus auto sync on create and edit.
- **Obsidian integration**: two-way sync through a third-party plugin, with daily notes and incremental sync.
- **WeRead import**: paste the exported text to import in bulk, with book, author and chapter detected automatically.
- **Annotations**: five types — comment, question, idea, important and to-do — in a sidebar you can add, edit and delete from.
- **Reference relations**: see outgoing and incoming links in a sidebar and jump straight to the linked note.
- **Custom AI prompts**: rewrite the review, continuation and insight prompts, or leave them empty for the default.

### Improved

- **Clearer import and export copy**: every capability is described consistently, with a data-safety note.
- **Complete bilingual text**: all new features ship with Chinese and English strings.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.0.8] - 2025-10-30

### Added

- **Full Chinese and English UI**: editor, cards, settings, import and service messages all switch language.
- **Nested tags**: separate levels with `/` and get a tree view, colours, statistics and search.
- **Flomo import**: bring in an HTML export, keeping creation times, migrating images and removing duplicates.

### Improved

- **Steadier AI and sync**: fewer tokens, smarter retries and more dependable conflict handling.
- **Images survive upgrades**: relative paths keep pictures visible after an update or reinstall.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.0.7] - 2025-09-15

### Added

- **Knowledge graph**: a visual map of how your notes relate to each other.
- **Activity heatmap**: track your writing habit month by month.
- **Note pinning**: keep important notes on top, synced to the server as well.
- **Custom fonts**: four sizes and six typefaces.

### Improved

- **Better search**: results are more relevant.
- **Faster sync**: syncing large libraries takes less time.
- **Refined interface**: spacing and controls feel more consistent.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.0.6] - 2025-08-01

### Added

- **AI assistant**: DeepSeek-powered writing help.
- **Voice input**: speak instead of typing, transcribed as you talk.
- **Scheduled reminders**: get notified about notes on a schedule.
- **Random review**: resurface past notes worth a second look.

### Improved

- **Better Markdown rendering**: more syntax displays as intended.
- **Smarter image handling**: images load and save more predictably.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.0.5] - 2025-07-01

### Added

- **Local references**: link notes with `[[Note Title]]`.
- **Backlinks**: see which notes point at the one you are reading.
- **WebDAV sync**: keep several devices in step.

### Improved

- **Stronger tags**: faster lookup and cleaner handling of nested names.
- **Cleaner interface**: tighter spacing and clearer hierarchy.

### Fixed

- Fixed known issues, improved stability and runtime efficiency.

## [1.0.0] - 2025-06-01

### Added

- First release: note taking with Markdown, tags, images and dark mode.
- Sync with a Memos server, plus a local-only mode.

---

For more details, visit our [GitHub Repository](https://github.com/liudengxing/InkPaper).
