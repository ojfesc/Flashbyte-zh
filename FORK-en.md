# Fork Notes

This repository is the Chinese-localized fork of Flashbyte, based on upstream v3.1.4.

- Upstream repository: https://github.com/iamsami101/Flashbyte
- Fork version: `3.1.4+0`
- Policy: features and fixes follow upstream; localization, desktop window handling, and release/packaging changes are maintained here.

Chinese version: [FORK.md](FORK.md).

## Shared with upstream

The following is identical to upstream 3.1.4 and is not modified by this fork:

- Device name defaults to the device model, falling back from internal model codes to brand / hostname
- Device name reset button, trusted device list (keyed by certificate fingerprint), "Always accept files from…"
- Share-menu file receiving, text-to-`.txt` conversion, direct send during an active session
- Android reads only `content://` URIs through SAF; plain file paths are read directly
- Release workflow: Windows self-signing (certificate, `flashbyte.exe`, installer), automatic changelog sectioning, `body_path: release-body.md`

## Changes in this fork

### Localization

- Added `lib/l10n/app_localizations.dart`: every UI string in Chinese and English
- Added `lib/app/controllers/app_locale_controller.dart`: language controller supporting system / Simplified Chinese / English
- Added a "Language" option in Settings; changes apply immediately and persist
- Notification channel names and UI hints refresh with the language setting
- Added `zh-Hans` permission descriptions for iOS and macOS (`Runner/{Base,zh-Hans}.lproj/InfoPlist.strings`)
- Added the macOS Chinese menu `Runner/zh-Hans.lproj/MainMenu.strings`
- Added `fastlane/metadata/android/zh-CN/`: Chinese store listing
- `README.md` now holds the Chinese text; `README-en.md` holds the English text
- `windows/installer/flashbyte.iss` gained a Simplified Chinese installer UI
- `install.sh` / `uninstall.sh` print Chinese or English based on `LANG`
- `linux/com.iamsami.flashbyte.desktop` gained a Chinese `Comment`

### Desktop window

- Added `lib/platform/window_state_manager.dart`: persists and restores window position, size, and maximized state
- The Linux / Windows / macOS native layers no longer show the window on the first frame; Dart restores the geometry first and then shows it
- macOS / Windows fade the window in over roughly 160 ms, avoiding a blank window and a position jump
- A restored position outside every display's visible area falls back to centered; when geometry is unavailable the previous position is kept
- `lib/main.dart` uses `WindowStateManager` instead of upstream's `windowManager.waitUntilReadyToShow`

### Transfer logic

- `device_discovery_service.dart`: `startDiscovery` / `startAdvertising` / `stop` are serialized through a queue so concurrent calls cannot corrupt the port and broadcast state
- `android_connection_notification_service.dart`: notification channel names are refreshed together with the language setting

### Release and packaging

- `release.yml` keeps the `Download Inno Setup Chinese Language File` step
- `release.yml` writes the README download tables per file: Chinese table in `README.md`, English table in `README-en.md`; a missing marker fails the job
- All other release steps match upstream

### Dependencies

- `flutter_localizations`, `intl`: UI localization
- `screen_retriever`: validates that a restored window still falls on a visible display

## Files that differ

### Added by this fork (12)

| File | Purpose |
|---|---|
| `lib/l10n/app_localizations.dart` | Chinese and English strings |
| `lib/app/controllers/app_locale_controller.dart` | Language controller |
| `lib/platform/window_state_manager.dart` | Window position and size persistence |
| `README-en.md` | English README |
| `ios/Runner/Base.lproj/InfoPlist.strings` | iOS permission descriptions (English) |
| `ios/Runner/zh-Hans.lproj/InfoPlist.strings` | iOS permission descriptions (Chinese) |
| `macos/Runner/Base.lproj/InfoPlist.strings` | macOS permission descriptions (English) |
| `macos/Runner/zh-Hans.lproj/InfoPlist.strings` | macOS permission descriptions (Chinese) |
| `macos/Runner/zh-Hans.lproj/MainMenu.strings` | macOS Chinese menu |
| `fastlane/metadata/android/zh-CN/full_description.txt` | Store long description (Chinese) |
| `fastlane/metadata/android/zh-CN/short_description.txt` | Store short description (Chinese) |
| `fastlane/metadata/android/zh-CN/changelogs/2.txt` | Store changelog (Chinese) |

### Upstream only (1)

| File | Notes |
|---|---|
| `.github/workflows/ci.yml` | This fork has no CI; enable it only after `dart format`, `flutter analyze`, `flutter test`, and `dart test -C packages/flashbyte_core` all pass locally |

### Modified (27)

| Group | Files |
|---|---|
| Localization | `lib/features/settings/settings_page.dart`, `lib/features/transfers/pages/file_selection_page.dart`, `incoming_transfer_offer_page.dart`, `outgoing_transfer_offer_page.dart`, `tcp_chat_page.dart`, `lib/features/transfers/widgets/transfer_widget.dart`, `file_preview_widget.dart`, `lib/app/app_settings.dart`, `lib/services/platform/android_saf_service.dart`, `lib/services/security/trusted_devices_service.dart`, `README.md` |
| Window | `lib/main.dart`, `linux/runner/my_application.cc`, `windows/runner/flutter_window.cpp`, `macos/Runner/MainFlutterWindow.swift` |
| Platform resources | `ios/Runner.xcodeproj/project.pbxproj`, `macos/Runner.xcodeproj/project.pbxproj`, `macos/Runner/Info.plist` |
| Transfer | `lib/services/discovery/device_discovery_service.dart`, `lib/services/platform/android_connection_notification_service.dart` |
| Release and packaging | `.github/workflows/release.yml`, `windows/installer/flashbyte.iss`, `linux/com.iamsami.flashbyte.desktop`, `install.sh`, `uninstall.sh` |
| Dependencies | `pubspec.yaml` (adds `flutter_localizations`, `intl`, `screen_retriever`) |

## Syncing upstream

1. Fetch the new upstream version and compare it against the file list above
2. Apply upstream feature changes to `lib/` and `packages/flashbyte_core/` only
3. Never let upstream overwrite:
   - `lib/l10n/`, `lib/app/controllers/app_locale_controller.dart`
   - `lib/platform/window_state_manager.dart` and the native window-show timing on all three desktop platforms
   - the dual-README section and the Inno Chinese language step in `release.yml`
   - `windows/installer/flashbyte.iss`, `install.sh`, `uninstall.sh`, `.desktop`
   - `CFBundleLocalizations` in `macos/Runner/Info.plist`
   - the `zh-Hans` / `Base` string files on every platform
4. Bump the `pubspec.yaml` version and update the `CHANGELOG.md` entries after syncing (the release workflow creates the dated version section automatically)
5. Update the file list above whenever files are added or removed
