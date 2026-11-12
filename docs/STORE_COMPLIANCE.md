# Store Compliance

Last updated: 2026-11-12

This document tracks the release checks required before submitting InkPaper to app stores. It is written for maintainers and store-review preparation. The project ships Android only, so Google Play is the only store channel.

## Google Play

Google Play requires apps with account creation to provide an in-app path for deleting app accounts and associated data, and a web link where users can request account and associated data deletion. The web link must work, be relevant, reference the app or developer name, and make the deletion pathway easy to discover. Source: [Google Play Console Help](https://support.google.com/googleplay/android-developer/answer/13327111).

Current app-side status:

- In-app deletion path exists at `Settings > Account and Data Deletion`.
- Public deletion URL is `https://inkpaper.cn/account-deletion.html`.
- Android manifest does not request broad photo/video access or exact-alarm special access. User-created reminders fall back to normal system alarms when exact scheduling is unavailable.

Before Google Play submission:

- Confirm the Data safety form discloses account/profile data, user content, photos/files, optional AI/WebDAV/Memos transfer, feedback, crash diagnostics, and Android analytics only when actually enabled.
- In the account deletion answers, provide `https://inkpaper.cn/account-deletion.html`.
- Reminders use normal system alarm fallback on Android 12+ when exact scheduling is unavailable; do not request exact-alarm special access unless the product is changed to a policy-eligible alarm/calendar use case.
- Build the signed AAB with the production keystore and verify upload signing configuration before rollout.

## Release Verification

Run locally or in CI before tagging:

```bash
dart tool/inkpaper.dart store-check
dart tool/inkpaper.dart verify
dart tool/inkpaper.dart build android-release
dart tool/inkpaper.dart build android-aab
```

Platform notes:

- Android builds require Android SDK, JDK 17, and release signing secrets. Google
  Play submission should use the signed AAB from
  `dart tool/inkpaper.dart build android-aab`.
- The repository has no other platform targets.
