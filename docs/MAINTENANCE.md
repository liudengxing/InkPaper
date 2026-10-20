# Maintenance

This document describes the project workflow for versioning, checks, builds, and releases.

## Version

`pubspec.yaml` is the source of truth for the application version.

```yaml
version: 1.1.13+10113
```

Do not duplicate the app version in platform files or Dart code. Flutter passes the version into Android, iOS, macOS, Windows, and Linux build metadata.

## CLI

Use the project CLI for repeatable local work:

```bash
dart tool/inkpaper.dart doctor
dart tool/inkpaper.dart verify
dart tool/inkpaper.dart verify --coverage
dart tool/inkpaper.dart store-check
dart tool/inkpaper.dart build android-debug
dart tool/inkpaper.dart build ios-sim
dart tool/inkpaper.dart build macos-debug
dart tool/inkpaper.dart build windows-debug
dart tool/inkpaper.dart build linux-debug
dart tool/inkpaper.dart release v1.1.13
```

Host-specific builds require matching local tools:

- Android requires an Android SDK.
- iOS simulator requires macOS, Xcode, and CocoaPods.
- macOS requires macOS and Xcode.
- Windows requires Windows and Visual Studio C++ desktop components.
- Linux requires GTK, CMake, Ninja, and system libraries used by the desktop plugins.

The shell entrypoint remains available for compatibility:

```bash
scripts/ci.sh all
```

## Continuous Integration

Pull requests and pushes run:

- Flutter dependency resolution.
- Static analysis.
- Automated tests.
- Secret scanning.
- Android APK build, and signed AAB build when `release_build` is enabled.
- iOS simulator build.
- macOS build.
- Windows build.
- Linux build.

The current CI and release workflows intentionally skip the Web platform.

## Store Compliance

Before submitting a commercial release to App Store Connect or Google Play,
check [`docs/STORE_COMPLIANCE.md`](STORE_COMPLIANCE.md).

Required public URLs:

- Privacy Policy: https://inkpaper.cn/privacy.html
- User Agreement: https://inkpaper.cn/agreement.html
- Account and Data Deletion: https://inkpaper.cn/account-deletion.html

The in-app deletion path is `Settings > Account and Data Deletion`. Keep the
website pages and the in-app legal text aligned whenever the data flow changes.

## Release

Release flow:

1. Update `pubspec.yaml`.
2. Update `CHANGELOG.md` and `CHANGELOG.en.md`.
3. Run `dart tool/inkpaper.dart store-check` and `dart tool/inkpaper.dart verify`.
4. Commit and push the changes.
5. Run `dart tool/inkpaper.dart release vX.Y.Z`.
6. Wait for the GitHub Actions Release workflow to finish.

The tag must match the version in `pubspec.yaml`. For `version: 1.1.13+10113`, the release tag is `v1.1.13`.

GitHub Actions publishes the release assets after all release jobs pass.

Release builds require these GitHub Actions secrets:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The official cloud verification AppID and client AppKey are fixed in source so
local, CI, and cloud CLI builds all use the production backend by default.
Android release builds must have signing credentials and also verify the signing
certificate fingerprint and APK/AAB package certificates before publishing.

GitHub Releases are for test and desktop distribution assets. Store submission
packages are prepared separately: iOS through Xcode archive/App Store Connect,
and Android through a signed AAB for Google Play.

## Security

Do not commit credentials, local configuration, private keys, certificates, user exports, or backup files. If a secret is exposed, revoke it and rotate the credential.
